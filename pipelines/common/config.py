"""Constantes compartidas por los pipelines de entrenamiento e inferencia."""

# Columnas que debe traer el dato crudo (ver diccionario.txt).
RAW_COLUMNS = [
    "TransId", "TransDate", "UserName", "CurrencyStr", "Actual_Stake", "Odds", "BetType",
    "Betteam", "Status", "Winlost", "ActualRate", "Winlostdate", "LiveIndicator",
    "BetGameTime", "MatchId", "SportId", "LeagueId", "WebId", "MaxBet",
]

# Columnas que no pueden venir nulas.
CRITICAL_COLUMNS = [
    "TransId", "TransDate", "UserName", "Actual_Stake", "Odds", "BetType", "Winlost", "ActualRate",
]

NUMERIC_COLUMNS = ["TransId", "Actual_Stake", "Odds", "BetType", "Winlost", "ActualRate"]

# Columnas que no se usan en la segmentación.
COLUMNS_TO_DROP = ["MatchId", "CurrencyStr", "Status", "Winlostdate", "BetGameTime", "WebId", "MaxBet"]

# Formato de la cuota según BetType.
DECIMAL_BETTYPES = [4, 5, 6, 8]   # ya en formato decimal
ASIAN_BETTYPES = [1, 2, 3, 7, 9]  # formato asiático
KNOWN_BETTYPES = DECIMAL_BETTYPES + ASIAN_BETTYPES

# Features por usuario (Profit_30d antes se llamaba LTV_Profit).
FEATURE_COLS = ["Recency", "Frequency", "Monetary", "Profit_30d", "Avg_Odds"]
USER_COL = "UserName"

WINSOR_MIN, WINSOR_MAX = 0.01, 0.99
VOLUME_TOLERANCE = 0.5  # ±50 % respecto a la corrida anterior
