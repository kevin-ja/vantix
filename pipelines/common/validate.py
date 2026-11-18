"""Validación del dato crudo. Corre en cada ejecución del pipeline (no es un test)."""
from __future__ import annotations

import pandas as pd

from pipelines.common.config import (
    CRITICAL_COLUMNS, KNOWN_BETTYPES, NUMERIC_COLUMNS, RAW_COLUMNS, VOLUME_TOLERANCE,
)


class DataValidationError(ValueError):
    """Agrupa todos los errores encontrados en una sola excepción."""


def validate(df: pd.DataFrame, reference_rows: int | None = None) -> None:
    """Revisa todas las reglas y lanza DataValidationError con la lista completa de errores."""
    errors: list[str] = []

    missing = [c for c in RAW_COLUMNS if c not in df.columns]
    if missing:
        raise DataValidationError(f"Faltan columnas: {missing}")

    # Tipos
    if not pd.api.types.is_datetime64_any_dtype(df["TransDate"]):
        errors.append("TransDate no es datetime")
    for c in NUMERIC_COLUMNS:
        if not pd.api.types.is_numeric_dtype(df[c]):
            errors.append(f"{c} no es numérica")

    # Nulos en columnas críticas
    nulls = df[CRITICAL_COLUMNS].isna().sum()
    for c, n in nulls[nulls > 0].items():
        errors.append(f"{c} tiene {n:,} nulos")

    # TransId repetido con contenido distinto (los duplicados exactos se limpian después)
    n_conflict = df.drop_duplicates()["TransId"].duplicated().sum()
    if n_conflict:
        errors.append(f"{n_conflict:,} TransId repetidos con contenido distinto")

    # Dominio
    unknown = set(df["BetType"].dropna().unique()) - set(KNOWN_BETTYPES)
    if unknown:
        errors.append(f"BetType no contemplados: {sorted(unknown)}")
    if (df["Odds"] == 0).any():
        errors.append(f"{(df['Odds'] == 0).sum():,} filas con Odds = 0")
    for c in ["Actual_Stake", "ActualRate"]:
        n = (df[c] <= 0).sum()
        if n:
            errors.append(f"{n:,} filas con {c} <= 0")

    # Volumen vs. corrida anterior
    if reference_rows:
        ratio = len(df) / reference_rows
        if abs(ratio - 1) > VOLUME_TOLERANCE:
            errors.append(f"Volumen {len(df):,} filas vs. {reference_rows:,} de referencia ({ratio:.0%})")

    if errors:
        raise DataValidationError("Validación fallida:\n- " + "\n- ".join(errors))
