"""Jobs del backend (doc §8.3, §8.7).

build_benchmark : data histórica del champion → métricas de referencia + bins del PSI + features de referencia.
run_monitoring  : data nueva → Data Quality + Data Drift vs. benchmark → Postgres → backup.
restore         : al arrancar, si la base está vacía, restaura el último backup de S3 (como Litestream en MLflow).

El benchmark queda atado al champion: benchmark/model_version=<v>/ en el bucket del monitoreo.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
from dataclasses import asdict
from pathlib import Path

import pandas as pd

from monitoring import db
from monitoring import settings as S
from monitoring.drift import drift, psi_bins
from monitoring.quality import data_quality, usable_rows
from pipelines.common import storage
from pipelines.common.config import FEATURE_COLS
from pipelines.common.features import build_user_features, clean
from pipelines.common.io import read_raw

log = logging.getLogger("monitoring")

BENCHMARK_FILE = "benchmark.json"
REFERENCE_FILE = "reference_features.parquet"
BACKUP_NAME = "monitoring.dump"


def git_commit() -> str:
    return os.environ.get("GIT_COMMIT", "unknown")


def load_manifest(champion_uri: str, tmp: Path) -> dict:
    return json.loads((storage.download_dir(champion_uri, tmp / "champion") / "manifest.json").read_text())


def load_raw(raw_uri: str, ingest_date: str, tmp: Path) -> pd.DataFrame:
    part = storage.join(raw_uri, f"ingest_date={ingest_date}")
    df = read_raw(storage.download_dir(part, tmp / "raw"))
    log.info("raw %s: %s filas", part, f"{len(df):,}")
    return df


def rfm(df: pd.DataFrame, snapshot_date: str, window_days: int) -> pd.DataFrame:
    """5 dimensiones RFM con el mismo cálculo que el entrenamiento, sobre las filas que este aceptaría."""
    return build_user_features(clean(df[usable_rows(df)]), snapshot_date, window_days)


def benchmark_uri(base: str, model_version: str) -> str:
    return storage.join(base, f"model_version={model_version}")


# ------------------------------------------------------------------------------------------------
def build_benchmark(*, raw_uri: str, champion_uri: str, benchmark_base: str, ingest_date: str,
                    window_days: int = S.WINDOW_DAYS) -> dict:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        manifest = load_manifest(champion_uri, tmp)
        version, snapshot = manifest["model_version"], manifest["snapshot_date"]
        raw = load_raw(raw_uri, ingest_date, tmp)

        quality = data_quality(raw, snapshot, window_days)
        feats = rfm(raw, snapshot, window_days)
        bins = {f: psi_bins(feats[f]) for f in FEATURE_COLS}
        meta = {
            "model_version": version, "run_id": manifest.get("run_id"), "ingest_date": ingest_date,
            "snapshot_date": snapshot, "window_days": window_days, "n_rows": len(raw), "n_users": len(feats),
            "git_commit": git_commit(),
            "data_quality": [asdict(m) for m in quality],
            "psi_bins": bins,  # cortes interiores; extremos −∞/+∞, bins (a, b]
        }

        out = tmp / "out"
        out.mkdir()
        feats[FEATURE_COLS].to_parquet(out / REFERENCE_FILE, index=False)
        (out / BENCHMARK_FILE).write_text(json.dumps(meta, indent=2, ensure_ascii=False))
        dest = benchmark_uri(benchmark_base, version)
        for name in (REFERENCE_FILE, BENCHMARK_FILE):  # benchmark.json al final: marca que está completo
            storage.upload_file(out / name, storage.join(dest, name))

    with db.connect() as conn:
        db.ensure_schema(conn)
        run_id = db.insert_run(conn, dataset="benchmark", model_version=version, ingest_date=ingest_date,
                               snapshot_date=snapshot, window_days=window_days, n_rows=len(raw),
                               n_users=meta["n_users"], git_commit=meta["git_commit"])
        db.insert_quality(conn, run_id, quality)
    log.info("benchmark v%s: %s usuarios → %s", version, f"{meta['n_users']:,}", dest)
    return meta


# ------------------------------------------------------------------------------------------------
def run_monitoring(*, raw_uri: str, champion_uri: str, benchmark_base: str, ingest_date: str = "auto",
                   snapshot_date: str = "auto", backup_uri: str | None = None) -> dict:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        version = load_manifest(champion_uri, tmp)["model_version"]
        try:
            bdir = storage.download_dir(benchmark_uri(benchmark_base, version), tmp / "benchmark")
        except FileNotFoundError:
            raise SystemExit(f"No hay benchmark para el champion v{version}: correr build_benchmark") from None
        bench = json.loads((bdir / BENCHMARK_FILE).read_text())
        reference = pd.read_parquet(bdir / REFERENCE_FILE)

        if ingest_date in ("", "auto"):
            ingest_date = storage.latest_partition(raw_uri, "ingest_date")
        if ingest_date <= bench["ingest_date"]:
            raise SystemExit(f"ingest_date={ingest_date} no es data nueva (benchmark: {bench['ingest_date']})")
        if snapshot_date in ("", "auto"):  # el lote ingerido el día D llega hasta D − 1 (igual que la inferencia)
            snapshot_date = (pd.Timestamp(ingest_date) - pd.Timedelta(days=1)).date().isoformat()
        window_days = bench["window_days"]
        raw = load_raw(raw_uri, ingest_date, tmp)

    quality = data_quality(raw, snapshot_date, window_days)
    feats, drifts, error = None, [], None
    try:
        feats = rfm(raw, snapshot_date, window_days)
        drifts = drift(reference, feats, bench["psi_bins"])
    except ValueError as e:  # p. ej. ventana sin transacciones: la calidad igual se registra
        error = str(e)

    with db.connect() as conn:
        db.ensure_schema(conn)
        run_id = db.insert_run(conn, dataset="new", model_version=version, ingest_date=ingest_date,
                               snapshot_date=snapshot_date, window_days=window_days, n_rows=len(raw),
                               n_users=None if feats is None else len(feats), git_commit=git_commit())
        db.insert_quality(conn, run_id, quality)
        db.insert_drift(conn, run_id, drifts)

    if backup_uri:
        backup(backup_uri)

    alerts = [m.metric for m in quality if m.alert] + [d.feature for d in drifts if d.alert]
    summary = {"run_id": run_id, "model_version": version, "ingest_date": ingest_date,
               "snapshot_date": snapshot_date, "alerts": alerts, "drift_error": error}
    log.info("corrida %s: %s", run_id, json.dumps(summary, ensure_ascii=False))
    if error:  # sin drift no hay corrida completa: el workflow tiene que verlo en rojo
        raise SystemExit(f"Drift no calculado: {error}")
    return summary


def backup(backup_uri: str) -> None:
    """pg_dump de toda la base al terminar la corrida (por evento, sin cron). El bucket versiona cada copia."""
    with tempfile.TemporaryDirectory() as t:
        dump = Path(t) / BACKUP_NAME
        subprocess.run(["pg_dump", "--format=custom", f"--file={dump}"], check=True)
        storage.upload_file(dump, storage.join(backup_uri, BACKUP_NAME))
    log.info("backup → %s", storage.join(backup_uri, BACKUP_NAME))


def restore(backup_uri: str) -> bool:
    """Restaura el último backup si la base no tiene corridas. Idempotente: corre en cada arranque de la EC2.

    Base vacía = volumen EBS nuevo (se perdió o se recreó): Postgres ya creó el esquema vacío (schema.sql).
    `--clean --if-exists` reemplaza esas tablas vacías por las del backup.
    """
    with db.connect() as conn:
        n = conn.execute("SELECT count(*) FROM runs").fetchone()[0] if conn.execute(
            "SELECT to_regclass('runs')").fetchone()[0] else 0
    if n:
        log.info("restore: la base ya tiene %s corridas, no se restaura", n)
        return False
    with tempfile.TemporaryDirectory() as t:
        try:
            dump = storage.download_dir(backup_uri, Path(t)) / BACKUP_NAME
        except FileNotFoundError:
            dump = None
        if dump is None or not dump.exists():
            log.info("restore: base vacía y sin backup en %s → se arranca de cero", backup_uri)
            return False
        subprocess.run(["pg_restore", "--clean", "--if-exists", "--no-owner", "--exit-on-error",
                        f"--dbname={os.environ.get('PGDATABASE', '')}", str(dump)], check=True)
    with db.connect() as conn:
        n = conn.execute("SELECT count(*) FROM runs").fetchone()[0]
    log.info("restore: %s corridas restauradas desde %s", n, storage.join(backup_uri, BACKUP_NAME))
    return True
