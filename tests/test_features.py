import numpy as np
import pandas as pd
import pytest

from pipelines.common.config import FEATURE_COLS
from pipelines.common.features import build_user_features, clean, odds_to_decimal, window_bounds


def test_window_bounds_include_snapshot_day():
    start, end = window_bounds("2025-04-30", 30)
    assert start == pd.Timestamp("2025-04-01")
    assert end == pd.Timestamp("2025-05-01")


def test_odds_to_decimal():
    odds = pd.Series([-1.07, 0.8, 2.5])
    bet_type = pd.Series([9, 1, 5])
    np.testing.assert_allclose(odds_to_decimal(odds, bet_type), [1 + 1 / 1.07, 1.8, 2.5])


def test_odds_to_decimal_unknown_bettype():
    with pytest.raises(ValueError):
        odds_to_decimal(pd.Series([1.5]), pd.Series([99]))


def test_build_user_features(raw_df):
    feats = build_user_features(clean(raw_df), "2025-04-30", 30).set_index("UserName")

    assert list(feats.columns) == FEATURE_COLS
    # La transacción de marzo (u3) queda fuera de la ventana.
    assert feats.loc["u3", "Frequency"] == 1
    assert feats.loc["u1", "Frequency"] == 2
    # Recency en días contra snapshot_date (la apuesta del mismo día cuenta 0).
    assert feats.loc["u2", "Recency"] == 0
    assert feats.loc["u1", "Recency"] == 10
    # Profit_30d = (stake - winlost) * rate
    assert feats.loc["u1", "Profit_30d"] == pytest.approx((100 - 193) * 0.085 + 50 * 0.085)


def test_empty_window(raw_df):
    with pytest.raises(ValueError, match="No hay transacciones"):
        build_user_features(clean(raw_df), "2024-01-01", 30)
