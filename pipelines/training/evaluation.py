"""Métricas de clustering (100 % de las observaciones) y perfil de negocio por cluster."""
from __future__ import annotations

import numpy as np
import pandas as pd
from sklearn.metrics import calinski_harabasz_score, davies_bouldin_score, silhouette_score

from pipelines.common.config import FEATURE_COLS


def clustering_metrics(X: np.ndarray, labels: np.ndarray, inertia: float) -> dict[str, float]:
    """Sin muestreo: silhouette con todas las observaciones (~45 s por k con ~108k usuarios)."""
    return {
        "inertia": float(inertia),
        "silhouette": float(silhouette_score(X, labels)),
        "calinski_harabasz": float(calinski_harabasz_score(X, labels)),
        "davies_bouldin": float(davies_bouldin_score(X, labels)),
    }


def cluster_profile(features: pd.DataFrame, labels: np.ndarray) -> pd.DataFrame:
    """Por cluster: n, % usuarios, media y mediana de las features, % profit y margen."""
    d = features[FEATURE_COLS].assign(cluster=labels)
    g = d.groupby("cluster")

    p = pd.DataFrame({"n": g.size()})
    p["pct_users"] = p["n"] / p["n"].sum() * 100
    for c in FEATURE_COLS:
        p[f"{c}_mean"] = g[c].mean()
        p[f"{c}_median"] = g[c].median()

    profit = g["Profit_30d"].sum()
    stake = g["Monetary"].sum()
    p["pct_profit"] = profit / profit.sum() * 100
    p["margin_pct"] = profit / stake * 100
    return p.sort_values("Monetary_mean").reset_index()
