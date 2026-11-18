"""Pasos 1-8 (Processing job): ingesta -> validación -> limpieza -> features -> transform -> predict -> escritura.

Todas las rutas son URIs (locales o s3://): el script descarga y sube él mismo, así controla el orden de
escritura (scores.parquet y summary.json primero, latest.json al final).

Local:      python -m pipelines.inference.steps.score --raw-uri data/raw --champion-uri .local/models/champion \
                --output-uri .local/scores --snapshot-date 2025-04-30 --scoring-date 2025-05-01
SageMaker:  --raw-uri s3://<datos>/raw --champion-uri s3://<datos>/models/champion --output-uri s3://<scores>/scores

"auto" en fechas: ingest_date = última partición de raw/, scoring_date = hoy (UTC), snapshot_date = scoring_date - 1.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import argparse  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import pandas as pd  # noqa: E402

from pipelines.common import storage  # noqa: E402
from pipelines.common.champion import Champion, load_champion  # noqa: E402
from pipelines.common.config import FEATURE_COLS, USER_COL  # noqa: E402
from pipelines.common.features import build_user_features, clean  # noqa: E402
from pipelines.common.io import read_raw, resolve_input, sha256_file  # noqa: E402
from pipelines.common.validate import validate  # noqa: E402

log = logging.getLogger("score")
AUTO = "auto"
OUTPUT_COLS = ["customer_id", "cluster_id", "segment_name", "model_version", "scoring_date"]


def parse_args(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--raw-uri", required=True, help="Base de raw/ (contiene ingest_date=…/)")
    p.add_argument("--champion-uri", required=True, help="Directorio models/champion/")
    p.add_argument("--output-uri", required=True, help="Base de scores/ (se escribe scoring_date=…/ y latest.json)")
    p.add_argument("--ingest-date", default=AUTO)
    p.add_argument("--snapshot-date", default=AUTO)
    p.add_argument("--scoring-date", default=AUTO)
    p.add_argument("--window-days", type=int, default=30)
    p.add_argument("--reference-rows", type=int, default=0, help="Filas de referencia (0 = no validar volumen)")
    return p.parse_args(argv)


def resolve_dates(ingest: str, snapshot: str, scoring: str, raw_uri: str) -> tuple[str, str, str]:
    scoring = datetime.now(timezone.utc).date().isoformat() if scoring in ("", AUTO) else scoring
    if snapshot in ("", AUTO):
        snapshot = (pd.Timestamp(scoring) - timedelta(days=1)).date().isoformat()
    if ingest in ("", AUTO):
        ingest = storage.latest_partition(raw_uri, "ingest_date")
    for name, value in (("ingest_date", ingest), ("snapshot_date", snapshot), ("scoring_date", scoring)):
        pd.Timestamp(value)  # falla si no es una fecha
        log.info("%s = %s", name, value)
    return ingest, snapshot, scoring


def check_coverage(df: pd.DataFrame, snapshot_date: str) -> None:
    """El lote debe llegar hasta snapshot_date; si no, Recency saldría inflada para todos."""
    last = pd.Timestamp(df["TransDate"].max()).normalize()
    if last < pd.Timestamp(snapshot_date):
        raise ValueError(f"El lote termina el {last.date()} y snapshot_date es {snapshot_date}: datos desactualizados")


def score(feats: pd.DataFrame, champ: Champion, scoring_date: str) -> pd.DataFrame:
    """Pasos 6-7: transform (sin fit) -> predict -> nombre del segmento."""
    Xt = champ.preprocessor.transform(feats[FEATURE_COLS])
    clusters = champ.model.predict(Xt)
    out = pd.DataFrame({
        "customer_id": feats[USER_COL].astype("string").to_numpy(),
        "cluster_id": clusters.astype("int32"),
    })
    out["segment_name"] = out["cluster_id"].map(champ.segment_map).astype("string")
    out["model_version"] = str(champ.manifest["model_version"])
    out["scoring_date"] = pd.Timestamp(scoring_date).date()
    return out[OUTPUT_COLS]


def validate_output(scores: pd.DataFrame, n_users: int, k: int) -> None:
    errors = []
    if len(scores) != n_users:
        errors.append(f"{len(scores):,} filas puntuadas vs. {n_users:,} usuarios")
    if scores["customer_id"].duplicated().any():
        errors.append("customer_id duplicados")
    if not scores["cluster_id"].between(0, k - 1).all():
        errors.append(f"cluster_id fuera de 0..{k - 1}")
    if scores[OUTPUT_COLS].isna().any().any():
        errors.append("nulos en la salida")
    if errors:
        raise ValueError("Salida inválida:\n- " + "\n- ".join(errors))


def main(argv=None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    a = parse_args(argv)
    t0 = time.time()

    ingest_date, snapshot_date, scoring_date = resolve_dates(a.ingest_date, a.snapshot_date, a.scoring_date, a.raw_uri)
    raw_part_uri = storage.join(a.raw_uri, f"ingest_date={ingest_date}")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        # 1. Ingesta
        raw_path = resolve_input(storage.download_dir(raw_part_uri, tmp / "raw"))
        raw = read_raw(raw_path)
        log.info("ingesta: %s filas desde %s", f"{len(raw):,}", raw_part_uri)

        # 2-3. Validación y limpieza (mismas funciones que entrenamiento)
        validate(raw, reference_rows=a.reference_rows or None)
        check_coverage(raw, snapshot_date)
        df = clean(raw)
        log.info("validación OK; %s filas tras limpieza", f"{len(df):,}")

        # 4. Features
        feats = build_user_features(df, snapshot_date, a.window_days)
        log.info("features: %s usuarios", f"{len(feats):,}")

        # 5. Artefactos del champion
        champ = load_champion(storage.download_dir(a.champion_uri, tmp / "champion"))
        k = int(champ.manifest["k"])
        log.info("champion: v%s (run %s, k=%d)", champ.manifest["model_version"], champ.manifest["run_id"], k)

        # 6-7. transform -> predict -> segmento
        scores = score(feats, champ, scoring_date)

        # 8. Validación de salida y escritura (latest.json al final)
        validate_output(scores, len(feats), k)
        part = f"scoring_date={scoring_date}"
        scores_path = tmp / "scores.parquet"
        scores.to_parquet(scores_path, index=False)

        counts = scores["segment_name"].value_counts()
        summary = {
            "scoring_date": scoring_date,
            "snapshot_date": snapshot_date,
            "window_days": a.window_days,
            "ingest_date": ingest_date,
            "raw_uri": raw_part_uri,
            "raw_sha256": sha256_file(raw_path),
            "raw_rows": int(len(raw)),
            "model_version": str(champ.manifest["model_version"]),
            "run_id": champ.manifest["run_id"],
            "k": k,
            "rows": int(len(scores)),
            "segments": {s: {"n": int(n), "pct": round(float(n) / len(scores) * 100, 2)} for s, n in counts.items()},
            "seconds": round(time.time() - t0, 1),
        }
        (tmp / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
        latest = {
            "scoring_date": scoring_date,
            "path": storage.join(a.output_uri, part, "scores.parquet"),
            "model_version": summary["model_version"],
            "rows": summary["rows"],
        }
        (tmp / "latest.json").write_text(json.dumps(latest, indent=2))

        storage.upload_file(scores_path, storage.join(a.output_uri, part, "scores.parquet"))
        storage.upload_file(tmp / "summary.json", storage.join(a.output_uri, part, "summary.json"))
        storage.upload_file(tmp / "latest.json", storage.join(a.output_uri, "latest.json"))

    log.info("scores: %s filas -> %s", f"{len(scores):,}", storage.join(a.output_uri, part))
    log.info("segmentos: %s", json.dumps(summary["segments"], ensure_ascii=False))


if __name__ == "__main__":
    main()
