"""Data Drift (doc §3.3): PSI y KS por dimensión RFM, data nueva vs. benchmark."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from scipy.stats import ks_2samp

from monitoring import settings as S


@dataclass
class Drift:
    feature: str
    psi: float
    psi_level: str
    ks: float
    ks_pvalue: float
    ks_level: str
    alert: bool


def psi_bins(x: pd.Series) -> list[float]:
    """Cortes interiores de los bins (deciles, sin repetidos). Los extremos son −∞ y +∞ (no se guardan)."""
    edges = np.unique(np.quantile(np.asarray(x, dtype=float), S.PSI_QUANTILES))
    return edges[1:-1].tolist()


def proportions(x: pd.Series, interior: list[float]) -> np.ndarray:
    """% por bin (a, b], cerrado a la derecha; bin vacío → PSI_EMPTY_BIN."""
    idx = np.searchsorted(np.asarray(interior, dtype=float), np.asarray(x, dtype=float), side="left")
    counts = np.bincount(idx, minlength=len(interior) + 1)
    p = counts / counts.sum()
    return np.where(p == 0, S.PSI_EMPTY_BIN, p)


def psi(reference: pd.Series, current: pd.Series, interior: list[float]) -> float:
    e, a = proportions(reference, interior), proportions(current, interior)
    return float(np.sum((a - e) * np.log(a / e)))


def drift(reference: pd.DataFrame, current: pd.DataFrame, bins: dict[str, list[float]]) -> list[Drift]:
    out = []
    for f, interior in bins.items():
        p = psi(reference[f], current[f], interior)
        ks = ks_2samp(reference[f], current[f])
        out.append(Drift(
            feature=f, psi=p, psi_level=S.level(p, S.PSI_LEVELS),
            ks=float(ks.statistic), ks_pvalue=float(ks.pvalue), ks_level=S.level(ks.statistic, S.KS_LEVELS),
            alert=p >= S.PSI_ALERT or ks.statistic >= S.KS_ALERT,
        ))
    return out
