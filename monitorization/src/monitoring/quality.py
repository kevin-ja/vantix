"""Las 5 métricas de Data Quality (doc §3.1) sobre las columnas que entran en las 5 dimensiones RFM.

Cada métrica es el % de filas afectadas, salvo completitud (días sin datos en la ventana).
A diferencia de pipelines.common.validate (un gate que corta la corrida), aquí solo se mide.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from monitoring import settings as S
from pipelines.common.config import ASIAN_BETTYPES, CRITICAL_COLUMNS, DECIMAL_BETTYPES, KNOWN_BETTYPES
from pipelines.common.features import window_bounds

NUMERIC = ["TransId", "Actual_Stake", "Odds", "BetType", "Winlost", "ActualRate"]


@dataclass
class Metric:
    metric: str
    value: float
    unit: str
    level: str
    alert: bool
    details: dict = field(default_factory=dict)


def _typed(df: pd.DataFrame) -> pd.DataFrame:
    """Columnas RFM con tipos forzados: lo que no se puede convertir queda NaN (y cuenta como inválido)."""
    d = df[CRITICAL_COLUMNS].copy()
    for c in NUMERIC:
        d[c] = pd.to_numeric(d[c], errors="coerce")
    d["TransDate"] = pd.to_datetime(d["TransDate"], errors="coerce")
    return d


def null_mask(df: pd.DataFrame) -> pd.DataFrame:
    """Nulo = NaN/None/NaT, string vacío o solo espacios. El 0 no es nulo."""
    d = df[CRITICAL_COLUMNS]
    mask = d.isna()
    for c in d.columns:
        if d[c].dtype == object or pd.api.types.is_string_dtype(d[c]):
            mask[c] |= d[c].astype("string").str.strip().eq("").fillna(False)
    return mask


def invalid_mask(df: pd.DataFrame, now: pd.Timestamp) -> pd.DataFrame:
    """Valor presente pero imposible para su columna (los nulos no cuentan aquí)."""
    raw, d, nulls = df[CRITICAL_COLUMNS], _typed(df), null_mask(df)
    valid = pd.DataFrame({
        "TransId": (d["TransId"] > 0) & (d["TransId"] % 1 == 0),
        "TransDate": d["TransDate"].notna() & (d["TransDate"] <= now),
        "UserName": raw["UserName"].astype("string").str.fullmatch(S.USERNAME_PATTERN).fillna(False),
        "Actual_Stake": d["Actual_Stake"] > 0,
        "ActualRate": d["ActualRate"] > 0,
        "Winlost": d["Winlost"] >= 0,
        "Odds": d["Odds"].notna() & (d["Odds"] != 0),
        "BetType": d["BetType"].isin(KNOWN_BETTYPES),
    })
    return ~valid.astype(bool) & ~nulls


def consistency_mask(df: pd.DataFrame) -> pd.DataFrame:
    """Valores válidos por separado que juntos no tienen sentido."""
    d = _typed(df)
    decimal = d["BetType"].isin(DECIMAL_BETTYPES)
    asian = d["BetType"].isin(ASIAN_BETTYPES)
    odds_ok = d["Odds"].notna() & (d["Odds"] != 0)

    # Misma conversión que pipelines.common.features.odds_to_decimal, solo donde está definida.
    with np.errstate(divide="ignore", invalid="ignore"):
        odds_dec = np.where(asian, np.where(d["Odds"] > 0, 1 + d["Odds"], 1 + 1 / d["Odds"].abs()), d["Odds"])
    max_payout = d["Actual_Stake"] * odds_dec * (1 + S.WINLOST_TOLERANCE)

    dedup = df.drop_duplicates()
    conflict_ids = dedup.loc[dedup["TransId"].duplicated(keep=False), "TransId"]
    return pd.DataFrame({
        "decimal_odds_le_1": decimal & (d["Odds"] <= 1),
        "winlost_gt_max_payout": (decimal | asian) & odds_ok & (d["Winlost"] > max_payout),
        "transid_conflict": df["TransId"].isin(conflict_ids),
    })


def missing_days(df: pd.DataFrame, snapshot_date: str, window_days: int) -> list[str]:
    start, end = window_bounds(snapshot_date, window_days)
    dates = pd.to_datetime(df["TransDate"], errors="coerce")
    present = set(dates[(dates >= start) & (dates < end)].dt.normalize())
    return [d.date().isoformat() for d in pd.date_range(start, end - pd.Timedelta(days=1)) if d not in present]


def _pct(mask: pd.Series) -> float:
    return float(mask.mean() * 100) if len(mask) else 0.0


def _strict(name: str, value: float, unit: str, details: dict) -> Metric:
    """Casos que el pipeline de entrenamiento no trata: cualquier presencia es alerta."""
    return Metric(name, value, unit, "alerta" if value > 0 else "ok", value > 0, details)


def data_quality(df: pd.DataFrame, snapshot_date: str, window_days: int = S.WINDOW_DAYS,
                 now: pd.Timestamp | None = None) -> list[Metric]:
    now = now or pd.Timestamp.now()
    nulls, invalid, inconsistent = null_mask(df), invalid_mask(df, now), consistency_mask(df)
    dup = df.duplicated()
    dup_pct = _pct(dup)
    missing = missing_days(df, snapshot_date, window_days)

    per_col = lambda m: {c: int(n) for c, n in m.sum().items() if n}  # noqa: E731
    return [
        _strict("nulls", _pct(nulls.any(axis=1)), "% filas", per_col(nulls)),
        Metric("duplicates", dup_pct, "% filas", S.level(dup_pct, S.DUPLICATE_LEVELS),
               dup_pct >= S.DUPLICATE_ALERT, {"rows": int(dup.sum())}),
        _strict("invalid", _pct(invalid.any(axis=1)), "% filas", per_col(invalid)),
        _strict("consistency", _pct(inconsistent.any(axis=1)), "% filas", per_col(inconsistent)),
        _strict("completeness", float(len(missing)), "días sin datos", {"missing_days": missing}),
    ]


def usable_rows(df: pd.DataFrame, now: pd.Timestamp | None = None) -> pd.Series:
    """Filas que el entrenamiento aceptaría (sin nulos ni inválidos en columnas RFM): base del drift."""
    now = now or pd.Timestamp.now()
    return ~(null_mask(df).any(axis=1) | invalid_mask(df, now).any(axis=1))
