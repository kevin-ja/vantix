"""Limpieza y features por usuario. Las usan entrenamiento e inferencia (mismo cálculo)."""
from __future__ import annotations

import numpy as np
import pandas as pd

from pipelines.common.config import (
    ASIAN_BETTYPES, COLUMNS_TO_DROP, DECIMAL_BETTYPES, FEATURE_COLS, USER_COL,
)


def clean(df: pd.DataFrame) -> pd.DataFrame:
    """Quita duplicados exactos y columnas que no se usan."""
    df = df.drop_duplicates().reset_index(drop=True)
    return df.drop(columns=[c for c in COLUMNS_TO_DROP if c in df.columns])


def odds_to_decimal(odds: pd.Series, bet_type: pd.Series) -> np.ndarray:
    """BetType 4, 5, 6, 8: ya decimal. 1, 2, 3, 7, 9 (asiático): x > 0 -> 1 + x ; x < 0 -> 1 + 1/|x|."""
    asian = bet_type.isin(ASIAN_BETTYPES)
    decimal = np.where(asian, np.where(odds > 0, 1 + odds, 1 + 1 / odds.abs()), odds)
    if not bet_type.isin(DECIMAL_BETTYPES + ASIAN_BETTYPES).all():
        raise ValueError("BetType no contemplado en la regla de cuotas")
    return decimal


def window_bounds(snapshot_date: str | pd.Timestamp, window_days: int) -> tuple[pd.Timestamp, pd.Timestamp]:
    """Ventana [start, end): los `window_days` días que terminan en `snapshot_date` (incluido)."""
    end = pd.Timestamp(snapshot_date).normalize() + pd.Timedelta(days=1)
    return end - pd.Timedelta(days=window_days), end


def build_user_features(df: pd.DataFrame, snapshot_date: str, window_days: int) -> pd.DataFrame:
    """Agrega por usuario las transacciones de la ventana. Devuelve UserName + FEATURE_COLS."""
    start, end = window_bounds(snapshot_date, window_days)
    d = df[(df["TransDate"] >= start) & (df["TransDate"] < end)].copy()
    if d.empty:
        raise ValueError(f"No hay transacciones en la ventana [{start.date()}, {end.date()})")

    d["Stake_SGD"] = d["Actual_Stake"] * d["ActualRate"]
    d["Profit_Company"] = (d["Actual_Stake"] - d["Winlost"]) * d["ActualRate"]
    d["Odds_decimal"] = odds_to_decimal(d["Odds"], d["BetType"])

    g = d.groupby(USER_COL)
    snapshot = pd.Timestamp(snapshot_date).normalize()
    feats = pd.DataFrame({
        "Recency": (snapshot - g["TransDate"].max().dt.normalize()).dt.days,
        "Frequency": g["TransId"].count(),
        "Monetary": g["Stake_SGD"].sum(),
        "Profit_30d": g["Profit_Company"].sum(),
        "Avg_Odds": g["Odds_decimal"].mean(),
    }).reset_index()

    if feats[USER_COL].duplicated().any() or len(feats) != d[USER_COL].nunique():
        raise ValueError("Usuarios perdidos o duplicados en la agregación")
    return feats[[USER_COL] + FEATURE_COLS]
