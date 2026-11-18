import sys
from pathlib import Path

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@pytest.fixture
def raw_df() -> pd.DataFrame:
    """Dato crudo mínimo y válido: 3 usuarios, BetType decimal y asiático."""
    return pd.DataFrame({
        "TransId": [1, 2, 3, 4, 5],
        "TransDate": pd.to_datetime(["2025-04-01 10:00", "2025-04-20 12:00", "2025-04-30 23:00",
                                     "2025-04-10 09:00", "2025-03-15 08:00"]),
        "UserName": ["u1", "u1", "u2", "u3", "u3"],
        "CurrencyStr": ["IDR"] * 5,
        "Actual_Stake": [100.0, 50.0, 200.0, 10.0, 30.0],
        "Odds": [-1.07, 2.5, 0.8, 1.9, 1.5],
        "BetType": [9, 5, 1, 4, 8],
        "Betteam": ["a", "h", "a", "h", "a"],
        "Status": ["WON", "LOSE", "LOSE", "WON", "LOSE"],
        "Winlost": [193.0, 0.0, 0.0, 19.0, 0.0],
        "ActualRate": [0.085, 0.085, 1.0, 1.0, 1.0],
        "Winlostdate": pd.to_datetime(["2025-04-01"] * 5),
        "LiveIndicator": [False, True, False, False, True],
        "BetGameTime": [None, "Live", None, None, "Live"],
        "MatchId": [1, 2, 3, 4, 5],
        "SportId": [2] * 5,
        "LeagueId": [187] * 5,
        "WebId": ["Web_003"] * 5,
        "MaxBet": [5000.0] * 5,
    })
