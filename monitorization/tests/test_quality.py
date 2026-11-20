import pandas as pd
import pytest

from monitoring.quality import data_quality, usable_rows

NOW = pd.Timestamp("2025-05-01")


def batch(n_days: int = 30) -> pd.DataFrame:
    """Lote limpio: una apuesta por día en la ventana que termina el 2025-04-30."""
    days = pd.date_range("2025-04-01", periods=n_days)
    return pd.DataFrame({
        "TransId": range(100, 100 + n_days),
        "TransDate": days + pd.Timedelta(hours=12),
        "UserName": [f"user_{i % 3}" for i in range(n_days)],
        "Actual_Stake": 100.0,
        "Odds": 1.85,
        "BetType": 5,          # decimal
        "Winlost": 185.0,      # = stake × cuota (máximo posible)
        "ActualRate": 0.085,
        "Status": "WON",
    })


def metrics(df):
    return {m.metric: m for m in data_quality(df, "2025-04-30", 30, now=NOW)}


def test_clean_batch_has_no_alerts():
    m = metrics(batch())
    assert all(not x.alert for x in m.values())
    assert all(x.value == 0 for x in m.values())


def test_zero_is_not_null_but_empty_string_is():
    df = batch()
    df.loc[0, "Winlost"] = 0.0          # apuesta perdida: válido
    df.loc[1, "UserName"] = "  "        # vacío: nulo
    m = metrics(df)
    assert m["nulls"].details == {"UserName": 1}
    assert m["invalid"].value == 0


@pytest.mark.parametrize("col,value", [
    ("Actual_Stake", 0.0), ("ActualRate", -1.0), ("Winlost", -5.0), ("Odds", 0.0),
    ("BetType", 12), ("UserName", "juan"), ("TransDate", pd.Timestamp("2030-01-01")),
])
def test_invalid_values(col, value):
    df = batch()
    df[col] = df[col].astype(object)
    df.loc[0, col] = value
    m = metrics(df)
    assert m["invalid"].alert and m["invalid"].details == {col: 1}


def test_consistency_rules():
    df = batch()
    df.loc[0, "Odds"], df.loc[0, "Winlost"] = 0.9, 0.0   # cuota decimal ≤ 1 (perdida)
    df.loc[1, "Winlost"] = 500.0                  # pago imposible (máx. 185)
    df.loc[2, "BetType"], df.loc[2, "Odds"] = 1, -2.0   # asiática negativa: decimal 1.5 → máx. 150
    df.loc[2, "Winlost"] = 150.0                  # justo el máximo: consistente
    df = pd.concat([df, df.iloc[[3]].assign(Winlost=0.0)])  # mismo TransId, otro contenido
    m = metrics(df)
    assert m["consistency"].details == {"decimal_odds_le_1": 1, "winlost_gt_max_payout": 1, "transid_conflict": 2}


def test_duplicates_ranges():
    df = batch(30)
    m = metrics(pd.concat([df, df.iloc[[0]]]))    # 1/31 = 3,2 % → considerable
    assert m["duplicates"].level == "considerable" and m["duplicates"].alert
    assert m["consistency"].value == 0            # duplicado exacto no es conflicto de TransId


def test_completeness_missing_days():
    m = metrics(batch(25))                        # faltan 04-26 … 04-30
    assert m["completeness"].value == 5 and m["completeness"].alert
    assert m["completeness"].details["missing_days"][0] == "2025-04-26"


def test_usable_rows_drops_nulls_and_invalid_only():
    df = batch()
    df.loc[0, "Actual_Stake"] = 0.0     # inválido
    df.loc[1, "Odds"] = 0.9             # inconsistente: el entrenamiento no lo descarta
    assert usable_rows(df, NOW).tolist() == [False] + [True] * 29
