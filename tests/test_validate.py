import pandas as pd
import pytest

from pipelines.common.validate import DataValidationError, validate


def test_valid_data_passes(raw_df):
    validate(raw_df)


def test_exact_duplicates_are_allowed(raw_df):
    validate(pd.concat([raw_df, raw_df.iloc[[0]]], ignore_index=True))


def test_missing_column(raw_df):
    with pytest.raises(DataValidationError, match="Faltan columnas"):
        validate(raw_df.drop(columns=["Odds"]))


def test_collects_all_errors(raw_df):
    bad = raw_df.copy()
    bad.loc[0, "UserName"] = None
    bad.loc[1, "BetType"] = 99
    bad.loc[2, "Odds"] = 0
    bad.loc[3, "Actual_Stake"] = -1
    with pytest.raises(DataValidationError) as e:
        validate(bad)
    msg = str(e.value)
    for expected in ["UserName tiene 1 nulos", "BetType no contemplados: [99]", "Odds = 0", "Actual_Stake <= 0"]:
        assert expected in msg


def test_conflicting_transid(raw_df):
    bad = pd.concat([raw_df, raw_df.iloc[[0]].assign(Actual_Stake=999.0)], ignore_index=True)
    with pytest.raises(DataValidationError, match="TransId repetidos"):
        validate(bad)


def test_wrong_date_type(raw_df):
    with pytest.raises(DataValidationError, match="TransDate no es datetime"):
        validate(raw_df.assign(TransDate=raw_df["TransDate"].astype(str)))


def test_volume_check(raw_df):
    validate(raw_df, reference_rows=6)
    with pytest.raises(DataValidationError, match="Volumen"):
        validate(raw_df, reference_rows=100)
