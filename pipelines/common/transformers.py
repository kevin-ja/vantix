"""Preprocesador serializable (preprocessor.pkl).

Esta ruta de módulo queda guardada dentro del .pkl: no mover sin regenerar los artefactos.
"""
from __future__ import annotations

import numpy as np
from sklearn.base import BaseEstimator, TransformerMixin
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import MinMaxScaler, PowerTransformer
from sklearn.utils.validation import check_is_fitted

from pipelines.common.config import WINSOR_MAX, WINSOR_MIN


class Winsorizer(BaseEstimator, TransformerMixin):
    """Aprende los percentiles en fit() y recorta con ellos en transform()."""

    def __init__(self, lower: float = WINSOR_MIN, upper: float = WINSOR_MAX):
        self.lower = lower
        self.upper = upper

    def fit(self, X, y=None):
        X = np.asarray(X, dtype=float)
        self.lower_bounds_ = np.quantile(X, self.lower, axis=0)
        self.upper_bounds_ = np.quantile(X, self.upper, axis=0)
        self.n_features_in_ = X.shape[1]
        return self

    def transform(self, X):
        check_is_fitted(self, ["lower_bounds_", "upper_bounds_"])
        return np.clip(np.asarray(X, dtype=float), self.lower_bounds_, self.upper_bounds_)


def build_preprocessor() -> Pipeline:
    """Yeo-Johnson (sin estandarizar) -> winsorización p1/p99 -> MinMax [0, 1]."""
    return Pipeline([
        ("yeo_johnson", PowerTransformer(method="yeo-johnson", standardize=False)),
        ("winsorizer", Winsorizer()),
        ("minmax", MinMaxScaler()),
    ])
