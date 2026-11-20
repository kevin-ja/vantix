"""Constantes del monitoreo: umbrales (doc §5) y parámetros de bins (doc §3.3).

Las columnas y las features vienen de pipelines.common.config: es la misma definición que usa el entrenamiento.
"""
from __future__ import annotations

import math

WINDOW_DAYS = 30  # misma ventana que el entrenamiento

# --- Data Drift (doc §5.1, §5.2, §5.2.1) -------------------------------------------------------
# Cada lista: (límite superior exclusivo, nivel). Se alerta desde "moderado".
KS_LEVELS = [(0.05, "pequeño"), (0.1, "moderado"), (0.2, "considerable"), (math.inf, "importante")]
PSI_LEVELS = [(0.1, "pequeño"), (0.25, "moderado"), (math.inf, "significativo")]
KS_ALERT = 0.05
PSI_ALERT = 0.1

# --- Bins del PSI (doc §3.3) -------------------------------------------------------------------
PSI_QUANTILES = [i / 10 for i in range(11)]  # deciles
PSI_EMPTY_BIN = 1e-4

# --- Data Quality (doc §5.3) -------------------------------------------------------------------
# Solo duplicados tiene rangos (el pipeline de entrenamiento los quita). El resto: > 0 → alerta.
DUPLICATE_LEVELS = [(0.5, "pequeño"), (1.0, "moderado"), (5.0, "considerable"), (math.inf, "importante")]
DUPLICATE_ALERT = 0.5  # %: desde "moderado", igual que el drift

# Consistencia: Winlost ≤ Stake × cuota decimal, con tolerancia por redondeo.
WINLOST_TOLERANCE = 1e-4  # 0,01 %
USERNAME_PATTERN = r"user_\d+"


def level(value: float, levels: list[tuple[float, str]]) -> str:
    for upper, name in levels:
        if value < upper:
            return name
    return levels[-1][1]
