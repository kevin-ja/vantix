"""Genera dos lotes crudos sintéticos para probar el monitoreo, a partir de la ventana histórica del benchmark.

  stable  : mismo comportamiento que la data histórica, desplazado a un período posterior. NO debe generar alertas.
            Usuarios renombrados y montos con ruido leve (stake y Winlost con el mismo factor: el pago sigue
            siendo coherente con la cuota). Mismos días con actividad → completitud 30/30.
  degraded: período posterior con problemas a propósito. DEBE generar muchas alertas.
            Calidad: nulos, duplicados (3 %), inválidos, inconsistencias y 3 días sin datos.
            Drift: menos apuestas por usuario (Frequency), montos ×4 (Monetary, Profit_30d), cuotas más altas
            (Avg_Odds) y la mitad de los usuarios deja de apostar 2 semanas antes del corte (Recency).

Cada lote cubre exactamente la ventana de 30 días que leerá run_monitoring (snapshot = ingest_date − 1 día):

    python monitorization/scripts/make_synthetic_batches.py --raw data/data.csv --out .local/raw_monitoring \
        --stable-ingest 2025-06-30 --degraded-ingest 2025-07-31
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from pipelines.common.config import ASIAN_BETTYPES, DECIMAL_BETTYPES  # noqa: E402
from pipelines.common.io import read_raw  # noqa: E402

WINDOW_DAYS = 30


def shift_to(df: pd.DataFrame, ref_start: pd.Timestamp, ingest: str, first_id: int) -> pd.DataFrame:
    """Lleva la ventana de referencia a la ventana [ingest − 30, ingest − 1] y renumera TransId/usuarios."""
    start = pd.Timestamp(ingest) - pd.Timedelta(days=WINDOW_DAYS)
    shift = start - ref_start
    out = df.copy()
    out["TransDate"] += shift
    out["Winlostdate"] = pd.to_datetime(out["Winlostdate"]) + shift
    out["TransId"] = np.arange(first_id, first_id + len(out), dtype="int64")
    users = {u: f"user_{first_id // 1000 + i}" for i, u in enumerate(out["UserName"].unique())}
    out["UserName"] = out["UserName"].map(users).astype("string")
    return out


def scale_money(df: pd.DataFrame, factor: np.ndarray) -> None:
    df["Actual_Stake"] *= factor
    df["Winlost"] *= factor  # mismo factor: Winlost ≤ Stake × cuota se mantiene


def stable(ref: pd.DataFrame, ref_start, ingest: str, rng) -> pd.DataFrame:
    out = shift_to(ref, ref_start, ingest, first_id=400_000_000)
    per_user = pd.Series(rng.lognormal(0, 0.05, out["UserName"].nunique()), index=out["UserName"].unique())
    scale_money(out, out["UserName"].map(per_user).to_numpy())
    return out


def degraded(ref: pd.DataFrame, ref_start, ingest: str, rng) -> pd.DataFrame:
    out = shift_to(ref, ref_start, ingest, first_id=500_000_000)
    snapshot = pd.Timestamp(ingest) - pd.Timedelta(days=1)

    # --- drift ---------------------------------------------------------------------------------
    keep = rng.random(len(out)) < 0.4                                    # Frequency: ~40 % de las apuestas
    keep |= ~out.duplicated("UserName")                                  # al menos una por usuario
    out = out[keep].copy()
    scale_money(out, np.full(len(out), 4.0))                             # Monetary / Profit_30d ×4
    dec, asian = out["BetType"].isin(DECIMAL_BETTYPES), out["BetType"].isin(ASIAN_BETTYPES)
    out.loc[dec, "Odds"] = out.loc[dec, "Odds"] * 1.6                    # Avg_Odds: cuotas más altas
    out.loc[asian & (out["Odds"] > 0), "Odds"] *= 1.6
    users = out["UserName"].unique()
    early = set(rng.choice(users, len(users) // 2, replace=False))       # Recency: la mitad se va antes
    cut = snapshot - pd.Timedelta(days=14)
    out = out[~(out["UserName"].isin(early) & (out["TransDate"] > cut))]

    # --- calidad -------------------------------------------------------------------------------
    out = out.reset_index(drop=True)
    n = len(out)
    pick = lambda frac: rng.choice(n, int(n * frac), replace=False)  # noqa: E731
    out.loc[pick(0.01), "UserName"] = pd.NA                            # nulos
    out.loc[pick(0.005), "Actual_Stake"] = 0.0                         # inválidos
    out.loc[pick(0.002), "BetType"] = 12
    dec_rows = out.index[out["BetType"].isin(DECIMAL_BETTYPES)]
    out.loc[rng.choice(dec_rows, len(dec_rows) // 50, replace=False), "Odds"] = 0.95   # inconsistentes
    gap = pd.date_range(snapshot - pd.Timedelta(days=9), periods=3)     # completitud: 3 días sin datos
    out = out[~out["TransDate"].dt.normalize().isin(gap)]
    out = pd.concat([out, out.sample(frac=0.03, random_state=7)])      # duplicados exactos (3 %)
    return out.sort_values("TransDate").reset_index(drop=True)


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--raw", required=True, help="Data histórica (csv o parquet)")
    p.add_argument("--out", required=True, help="Directorio base: se escribe <out>/ingest_date=<fecha>/data.parquet")
    p.add_argument("--ref-start", default="2025-04-01", help="Inicio de la ventana histórica del benchmark")
    p.add_argument("--stable-ingest", default="2025-06-30")
    p.add_argument("--degraded-ingest", default="2025-07-31")
    p.add_argument("--seed", type=int, default=42)
    a = p.parse_args(argv)

    raw = read_raw(a.raw)
    ref_start = pd.Timestamp(a.ref_start)
    ref = raw[(raw["TransDate"] >= ref_start) & (raw["TransDate"] < ref_start + pd.Timedelta(days=WINDOW_DAYS))]
    rng = np.random.default_rng(a.seed)
    for name, ingest, fn in (("stable", a.stable_ingest, stable), ("degraded", a.degraded_ingest, degraded)):
        df = fn(ref, ref_start, ingest, rng)
        dest = Path(a.out) / f"ingest_date={ingest}" / "data.parquet"
        dest.parent.mkdir(parents=True, exist_ok=True)
        df.to_parquet(dest, index=False)
        print(f"{name:9s} {ingest}: {len(df):,} filas, {df['UserName'].nunique():,} usuarios → {dest}")


if __name__ == "__main__":
    main()
