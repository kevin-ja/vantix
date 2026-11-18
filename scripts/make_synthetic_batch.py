"""Genera un lote crudo sintético (mismo esquema que data/data.csv) para probar la inferencia.

Datos nunca vistos pero realistas: cada usuario nuevo (user_200001, …) toma como plantilla el
comportamiento de un usuario real de la ventana de referencia y se perturba:
  - fechas desplazadas `--shift-days` (+ hasta 24 h de ruido por usuario, sin salir de la ventana destino);
  - actividad: se conserva entre 60 % y 100 % de sus apuestas (al menos una);
  - montos: Actual_Stake y Winlost escalados por un factor lognormal por usuario (el resultado de la
    apuesta se mantiene coherente con la cuota y el Status);
  - TransId nuevos (por encima del máximo histórico).

    python scripts/make_synthetic_batch.py --csv data/data.csv \
        --out .local/raw_synth/ingest_date=2025-05-31/data.csv --users 15000
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--csv", default="data/data.csv")
    p.add_argument("--out", required=True)
    p.add_argument("--users", type=int, default=15_000)
    p.add_argument("--ref-start", default="2025-04-01", help="Inicio de la ventana de referencia")
    p.add_argument("--ref-end", default="2025-05-01", help="Fin (exclusivo) de la ventana de referencia")
    p.add_argument("--shift-days", type=int, default=30)
    p.add_argument("--seed", type=int, default=7)
    a = p.parse_args(argv)
    rng = np.random.default_rng(a.seed)

    raw = pd.read_csv(a.csv, parse_dates=["TransDate"]).drop_duplicates()
    ref = raw[(raw["TransDate"] >= a.ref_start) & (raw["TransDate"] < a.ref_end)]
    templates = rng.choice(ref["UserName"].unique(), size=a.users, replace=True)
    by_user = dict(tuple(ref.groupby("UserName")))

    shift = pd.Timedelta(days=a.shift_days)
    limit = pd.Timestamp(a.ref_end) + shift  # fin exclusivo de la ventana destino
    parts = []
    for i, tpl in enumerate(templates, start=1):
        t = by_user[tpl]
        keep = max(1, int(round(len(t) * rng.uniform(0.6, 1.0))))
        t = t.sample(n=keep, random_state=int(rng.integers(1 << 31))).copy()
        jitter = pd.Timedelta(hours=float(rng.uniform(0, 24)))
        moved = t["TransDate"] + shift
        t["TransDate"] = moved.where(moved + jitter >= limit, moved + jitter)  # sin ruido si saldría de la ventana
        t["Winlostdate"] = (pd.to_datetime(t["Winlostdate"]) + shift).dt.strftime("%Y-%m-%d")
        f = float(rng.lognormal(0.0, 0.3))
        t["Actual_Stake"] = (t["Actual_Stake"] * f).round(2)
        t["Winlost"] = (t["Winlost"] * f).round(2)
        t["UserName"] = f"user_{200_000 + i}"
        parts.append(t)

    out = pd.concat(parts, ignore_index=True).sort_values("TransDate", kind="stable")
    out = out[out["Actual_Stake"] > 0]
    out["TransId"] = np.arange(raw["TransId"].max() + 1, raw["TransId"].max() + 1 + len(out))
    out["TransDate"] = out["TransDate"].dt.strftime("%Y-%m-%d %H:%M:%S.%f").str[:-3]

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    out[raw.columns].to_csv(a.out, index=False)
    print(f"{len(out):,} transacciones · {out['UserName'].nunique():,} usuarios nuevos · "
          f"{out['TransDate'].min()} → {out['TransDate'].max()} -> {a.out}")


if __name__ == "__main__":
    main()
