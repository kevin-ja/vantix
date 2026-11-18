"""Paso 1-4 (Processing job): ingesta -> validación -> limpieza -> features.

Local:      python -m pipelines.training.steps.prepare --input data/data.csv --output-dir .local/prepare ...
SageMaker:  --input /opt/ml/processing/input/raw --output-dir /opt/ml/processing/output

Salidas:
  <output-dir>/features/user_features.parquet
  <output-dir>/metadata/metadata.json   (hash de datos, ventana, conteos; lo registra el paso de train)
"""
from __future__ import annotations

import sys
from pathlib import Path

# En el contenedor el script corre suelto: hace importable el paquete `pipelines`.
ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import argparse  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402

from pipelines.common.features import build_user_features, clean, window_bounds  # noqa: E402
from pipelines.common.io import read_raw, resolve_input, sha256_file  # noqa: E402
from pipelines.common.validate import validate  # noqa: E402

log = logging.getLogger("prepare")


def parse_args(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="Archivo o directorio con el dato crudo")
    p.add_argument("--output-dir", required=True)
    p.add_argument("--snapshot-date", required=True, help="YYYY-MM-DD; Recency se calcula contra esta fecha")
    p.add_argument("--window-days", type=int, default=30)
    p.add_argument("--reference-rows", type=int, default=0, help="Filas de la corrida anterior (0 = no validar volumen)")
    p.add_argument("--raw-uri", default="", help="URI de origen, solo para trazabilidad")
    return p.parse_args(argv)


def main(argv=None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    a = parse_args(argv)

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
    (out / "metadata").mkdir(parents=True, exist_ok=True)
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
    (out / "metadata" / "metadata.json").write_text(json.dumps(metadata, indent=2))
    log.info("metadata: %s", metadata)


if __name__ == "__main__":
    main()
