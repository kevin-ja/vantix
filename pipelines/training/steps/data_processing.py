"""Paso 1-4 (Processing job): ingesta -> validación -> limpieza -> features.

SageMaker:  --input /opt/ml/processing/input/raw --output-dir /opt/ml/processing/output --execution-id <id>

Salidas:
  <output-dir>/features/user_features.parquet   (las lee el paso model_training)
  MLflow: crea el run padre de la corrida y registra la metadata de los datos (origen, hashes, ventana, conteos)
          como parámetros, data/metadata.json y dataset de entrada. Lo etiqueta con el id de la ejecución del
          pipeline (tag pipeline_execution_id): así model_training encuentra el run y sigue en él, sin pasar archivos.
"""
from __future__ import annotations

import sys
from pathlib import Path

# En el contenedor el script corre suelto: hace importable el paquete `pipelines`.
ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import argparse  # noqa: E402
import logging  # noqa: E402
import os  # noqa: E402

import mlflow  # noqa: E402
import mlflow.data  # noqa: E402

from pipelines.common.features import build_user_features, clean, window_bounds  # noqa: E402
from pipelines.common.io import read_raw, resolve_input, sha256_file  # noqa: E402
from pipelines.common.mlflow_auth import configure_credentials  # noqa: E402
from pipelines.common.validate import validate  # noqa: E402

log = logging.getLogger("data_processing")
EXPERIMENT = "vantix-segmentation"
EXECUTION_TAG = "pipeline_execution_id"


def parse_args(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="Archivo o directorio con el dato crudo")
    p.add_argument("--output-dir", required=True)
    p.add_argument("--snapshot-date", required=True, help="YYYY-MM-DD; Recency se calcula contra esta fecha")
    p.add_argument("--window-days", type=int, default=30)
    p.add_argument("--reference-rows", type=int, default=0,
                   help="Filas de la corrida anterior (0 = no validar volumen)")
    p.add_argument("--raw-uri", default="", help="URI de origen, solo para trazabilidad")
    p.add_argument("--features-uri", default="", help="URI de destino de las features, solo para trazabilidad")
    p.add_argument("--execution-id", required=True,
                   help="Id de la ejecución del pipeline (une data_processing y model_training)")
    p.add_argument("--tracking-uri", default=os.environ.get("MLFLOW_TRACKING_URI"))
    p.add_argument("--experiment", default=EXPERIMENT)
    return p.parse_args(argv)


def main(argv=None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    a = parse_args(argv)
    if not a.tracking_uri:
        raise ValueError("Falta --tracking-uri o MLFLOW_TRACKING_URI")

    raw_path = resolve_input(a.input)
    raw = read_raw(raw_path)
    log.info("ingesta: %s filas x %s columnas", f"{len(raw):,}", raw.shape[1])

    validate(raw, reference_rows=a.reference_rows or None)
    log.info("validación OK")

    df = clean(raw)
    log.info("limpieza: %s filas tras quitar duplicados exactos", f"{len(df):,}")

    feats = build_user_features(df, a.snapshot_date, a.window_days)
    log.info("features: %s usuarios", f"{len(feats):,}")

    out = Path(a.output_dir)
    (out / "features").mkdir(parents=True, exist_ok=True)
    feats_path = out / "features" / "user_features.parquet"
    feats.to_parquet(feats_path, index=False)

    start, end = window_bounds(a.snapshot_date, a.window_days)
    metadata = {
        "snapshot_date": a.snapshot_date,
        "window_days": a.window_days,
        "window_start": str(start.date()),
        "window_end_exclusive": str(end.date()),
        "raw_uri": a.raw_uri or str(raw_path),
        "raw_sha256": sha256_file(raw_path),
        "raw_rows": int(len(raw)),
        "clean_rows": int(len(df)),
        "n_users": int(len(feats)),
        "features_sha256": sha256_file(feats_path),
    }
    log.info("metadata: %s", metadata)
    log_data_run(a, metadata, feats)


def log_data_run(a, metadata: dict, feats) -> str:
    """Crea el run padre de la corrida en MLflow con la metadata de los datos; devuelve su id."""
    configure_credentials(a.tracking_uri)
    mlflow.set_tracking_uri(a.tracking_uri)
    mlflow.set_experiment(a.experiment)
    params = ("snapshot_date", "window_days", "n_users", "raw_uri", "raw_sha256", "features_sha256")
    with mlflow.start_run(run_name=f"snapshot={metadata['snapshot_date']}",
                          tags={EXECUTION_TAG: a.execution_id}) as run:
        mlflow.log_params({k: metadata[k] for k in params})
        mlflow.log_dict(metadata, "data/metadata.json")
        dataset = mlflow.data.from_pandas(feats, source=a.features_uri or metadata["raw_uri"], name="user_features",
                                          digest=metadata["features_sha256"][:8])
        mlflow.log_input(dataset, context="training")
    log.info("MLflow: run padre %s (%s=%s)", run.info.run_id, EXECUTION_TAG, a.execution_id)
    return run.info.run_id


if __name__ == "__main__":
    main()
