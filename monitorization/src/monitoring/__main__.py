"""CLI del backend: python -m monitoring {build_benchmark,run_monitoring} [...]

Rutas por defecto desde el entorno (las escribe la EC2): DATA_BUCKET y MONITORING_BUCKET.
Para correr en local se pasan rutas locales (--raw-uri, --champion-uri, --benchmark-uri) y --no-backup.
"""
from __future__ import annotations

import argparse
import logging
import os

from monitoring import jobs


def _default(env: str, suffix: str) -> str | None:
    bucket = os.environ.get(env)
    return f"s3://{bucket}/{suffix}" if bucket else None


def main(argv=None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    p = argparse.ArgumentParser(prog="monitoring")
    sub = p.add_subparsers(dest="job", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--raw-uri", default=_default("DATA_BUCKET", "raw"))
    common.add_argument("--champion-uri", default=_default("DATA_BUCKET", "models/champion"))
    common.add_argument("--benchmark-uri", default=_default("MONITORING_BUCKET", "benchmark"))

    b = sub.add_parser("build_benchmark", parents=[common], help="Benchmark del champion actual")
    b.add_argument("--ingest-date", required=True, help="Partición raw/ con la que se entrenó el champion")

    r = sub.add_parser("run_monitoring", parents=[common], help="Corrida sobre la data nueva")
    r.add_argument("--ingest-date", default="auto", help="auto = última partición de raw/")
    r.add_argument("--snapshot-date", default="auto", help="auto = ingest_date − 1 día")
    r.add_argument("--backup-uri", default=_default("MONITORING_BUCKET", "backups"))
    r.add_argument("--no-backup", action="store_true")

    a = p.parse_args(argv)
    missing = [k for k in ("raw_uri", "champion_uri", "benchmark_uri") if not getattr(a, k)]
    if missing:
        p.error(f"faltan rutas: {missing} (definir DATA_BUCKET/MONITORING_BUCKET o pasarlas)")

    paths = dict(raw_uri=a.raw_uri, champion_uri=a.champion_uri, benchmark_base=a.benchmark_uri)
    if a.job == "build_benchmark":
        jobs.build_benchmark(**paths, ingest_date=a.ingest_date)
    else:
        jobs.run_monitoring(**paths, ingest_date=a.ingest_date, snapshot_date=a.snapshot_date,
                            backup_uri=None if a.no_backup else a.backup_uri)


if __name__ == "__main__":
    main()
