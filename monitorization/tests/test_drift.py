import numpy as np
import pandas as pd
import pytest

from monitoring.drift import drift, proportions, psi, psi_bins


def test_bins_are_deciles_without_repeats():  # deciles repetidos se fusionan
    assert psi_bins(pd.Series(range(1, 101))) == pytest.approx([10.9, 20.8, 30.7, 40.6, 50.5, 60.4, 70.3, 80.2, 90.1])
    assert psi_bins(pd.Series([1, 1, 1, 1, 1, 1, 2, 3, 4, 5])) == pytest.approx([1.4, 2.3, 3.2, 4.1])


def test_bins_closed_right_and_open_ends():
    p = proportions(pd.Series([-100, 1, 2, 1000]), [1.0, 2.0])
    assert p.tolist() == [0.5, 0.25, 0.25]       # (−∞,1] (1,2] (2,+∞)


def test_empty_bin_gets_epsilon():
    assert proportions(pd.Series([5, 6]), [1.0])[0] == 1e-4


def test_psi_zero_for_same_distribution_and_positive_for_shift():
    rng = np.random.default_rng(0)
    ref = pd.Series(rng.normal(size=20_000))
    bins = psi_bins(ref)
    assert psi(ref, ref, bins) == 0
    assert psi(ref, pd.Series(rng.normal(0.5, size=20_000)), bins) > 0.1


def test_alert_from_moderate():
    rng = np.random.default_rng(1)
    ref = pd.DataFrame({"Monetary": rng.normal(size=20_000)})
    same = pd.DataFrame({"Monetary": rng.normal(size=20_000)})
    shifted = pd.DataFrame({"Monetary": rng.normal(0.5, size=20_000)})
    bins = {"Monetary": psi_bins(ref["Monetary"])}
    assert not drift(ref, same, bins)[0].alert
    d = drift(ref, shifted, bins)[0]
    assert d.alert and d.ks >= 0.05
