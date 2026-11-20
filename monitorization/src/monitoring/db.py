"""PostgreSQL: una fila por corrida (runs) y sus métricas (data_quality, data_drift).

La conexión sale de las variables estándar de libpq (PGHOST, PGDATABASE, PGUSER, PGPASSWORD).
`alert` lo calcula el backend con los umbrales de settings.py: Grafana solo lee esa columna,
así los umbrales viven en un único lugar.
"""
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

import psycopg

SCHEMA = (Path(__file__).with_name("schema.sql")).read_text()


def connect() -> psycopg.Connection:
    return psycopg.connect()


def ensure_schema(conn: psycopg.Connection) -> None:
    conn.execute(SCHEMA)


def insert_run(conn: psycopg.Connection, **run) -> int:
    cols = ", ".join(run)
    marks = ", ".join(f"%({k})s" for k in run)
    return conn.execute(f"INSERT INTO runs ({cols}) VALUES ({marks}) RETURNING run_id", run).fetchone()[0]


def insert_quality(conn: psycopg.Connection, run_id: int, metrics: list) -> None:
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO data_quality (run_id, metric, value, unit, level, alert, details) "
            "VALUES (%(run_id)s, %(metric)s, %(value)s, %(unit)s, %(level)s, %(alert)s, %(details)s)",
            [{**asdict(m), "run_id": run_id, "details": json.dumps(m.details)} for m in metrics],
        )


def insert_drift(conn: psycopg.Connection, run_id: int, drifts: list) -> None:
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO data_drift (run_id, feature, psi, psi_level, ks, ks_pvalue, ks_level, alert) "
            "VALUES (%(run_id)s, %(feature)s, %(psi)s, %(psi_level)s, %(ks)s, %(ks_pvalue)s, %(ks_level)s, %(alert)s)",
            [{**asdict(d), "run_id": run_id} for d in drifts],
        )
