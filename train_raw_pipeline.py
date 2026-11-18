"""
Pipeline de segmentación de clientes (RFM + KMeans, k=5).

Versión en funciones del flujo de `src_optimo.ipynb`:

    1. Ingesta             -> ingest()
    2. Limpieza            -> clean()
    3. Feature engineering -> feature_engineering()
    4. Preprocesamiento    -> preprocess()
    5. Modelado            -> train()
    6. Evaluación          -> evaluate()
    7. Pipeline completo   -> run_pipeline()

Uso (desde la raíz del repo):
    python train_raw_pipeline.py

Las transformaciones de preprocesamiento (yj, winzor, minmaxscaler) se importan
de `src/cluster.py`, igual que en los notebooks.
"""

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.metrics import calinski_harabasz_score, davies_bouldin_score, silhouette_score

from src.cluster import minmaxscaler, winzor, yj

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
RAW_DATA_PATH = "data/data.csv"

COLUMNS_TO_DROP = ["MatchId", "CurrencyStr", "Status", "Winlostdate", "BetGameTime", "WebId", "MaxBet"]

RFM_COLS = ["Recency", "Frequency", "Monetary", "LTV_Profit", "Avg_Odds"]

# Formato de la cuota según BetType (ver paso 5.1 de src_optimo.ipynb)
DECIMAL_BETTYPES = [4, 5, 6, 8]   # ya en formato decimal
ASIAN_BETTYPES = [1, 2, 3, 7, 9]  # formato asiático

WINSOR_MIN, WINSOR_MAX = 0.01, 0.99
K = 5
KMEANS_PARAMS = dict(random_state=42, n_init=10)


# ---------------------------------------------------------------------------
# 1. Ingesta
# ---------------------------------------------------------------------------
def ingest(path=RAW_DATA_PATH):
    """Paso 1: lee el dataset crudo de transacciones."""
    d = pd.read_csv(path)
    print(f"[ingesta] {d.shape[0]:,} filas x {d.shape[1]} columnas")
    return d


# ---------------------------------------------------------------------------
# 2. Limpieza
# ---------------------------------------------------------------------------
def clean(d):
    """
    Pasos 1.1, 2 y 6:
      - 1.1 elimina filas duplicadas exactas (antes de borrar columnas).
      - 2   elimina columnas que no se usan.
      - 6   convierte TransDate a datetime.
    """
    d = d.copy()

    n_dup = d.duplicated().sum()
    d = d.drop_duplicates().reset_index(drop=True)
    assert d["TransId"].is_unique, "Quedan TransId repetidos con contenido distinto"

    d = d.drop(columns=COLUMNS_TO_DROP)
    d["TransDate"] = pd.to_datetime(d["TransDate"])

    print(f"[limpieza] duplicados eliminados: {n_dup:,} | quedan {d.shape[0]:,} filas x {d.shape[1]} columnas")
    return d


# ---------------------------------------------------------------------------
# 3. Feature engineering
# ---------------------------------------------------------------------------
def convert_odds_to_decimal(odds, bet_type):
    """
    Paso 5.1: convierte Odds a cuota decimal según el BetType.
      - BetType 4, 5, 6, 8     -> ya es decimal.
      - BetType 1, 2, 3, 7, 9  -> asiático: x > 0 -> 1 + x ; x < 0 -> 1 + 1/|x|
    """
    assert set(bet_type.unique()) <= set(DECIMAL_BETTYPES + ASIAN_BETTYPES), "BetType no contemplado en la regla"
    assert (odds != 0).all()

    decimal = np.where(
        bet_type.isin(DECIMAL_BETTYPES),
        odds,
        np.where(odds > 0, 1 + odds, 1 + 1 / odds.abs()),
    )
    assert (decimal >= 1).all()
    return decimal


def feature_engineering(d):
    """
    Pasos 4, 5, 5.1, 7, 8 y 9:
      - 4   Stake_SGD      = Actual_Stake * ActualRate
      - 5   Profit_Company = (Actual_Stake - Winlost) * ActualRate
      - 5.1 Odds_decimal   = cuota convertida a formato decimal
      - 7   fecha de referencia para la recencia = fecha máxima del dataset
      - 8-9 agregación por usuario y renombrado a RFM_COLS
    """
    d = d.copy()
    d["Stake_SGD"] = d["Actual_Stake"] * d["ActualRate"]
    d["Profit_Company"] = (d["Actual_Stake"] - d["Winlost"]) * d["ActualRate"]
    d["Odds_decimal"] = convert_odds_to_decimal(d["Odds"], d["BetType"])

    fecha_referencia = d["TransDate"].max()

    user_agg = d.groupby("UserName").agg({
        "TransDate": lambda x: (fecha_referencia - x.max()).days,
        "TransId": "count",
        "Stake_SGD": "sum",
        "Profit_Company": "sum",
        "Odds_decimal": "mean",
    })
    user_agg = user_agg.rename(columns={
        "TransDate": "Recency",
        "TransId": "Frequency",
        "Stake_SGD": "Monetary",
        "Profit_Company": "LTV_Profit",
        "Odds_decimal": "Avg_Odds",
    }).reset_index()

    # Test de integridad: ningún usuario se pierde ni se duplica en la agregación
    assert set(d["UserName"].unique()) == set(user_agg["UserName"]), "Usuarios perdidos o duplicados"

    print(f"[feature engineering] {len(user_agg):,} usuarios x {len(RFM_COLS)} variables")
    return user_agg


# ---------------------------------------------------------------------------
# 4. Preprocesamiento
# ---------------------------------------------------------------------------
def preprocess(user_agg, cols=RFM_COLS):
    """
    Pasos 10 y 11 (funciones de src/cluster.py):
      - 10  Yeo-Johnson (standardize=False) + winsorización entre los percentiles 1% y 99%
      - 11  MinMaxScaler a [0, 1]
    Devuelve la matriz X (numpy) lista para KMeans.
    """
    df = user_agg[cols].copy()

    yj_df, _ = yj(df, cols)                                       # 10.a Yeo-Johnson
    w_df = winzor(yj_df, cols, min=WINSOR_MIN, max=WINSOR_MAX)    # 10.b Winsorización
    df = minmaxscaler(w_df, cols)                                 # 11.  MinMax

    print(f"[preprocesamiento] matriz de entrenamiento {df.shape}")
    return df.values


# ---------------------------------------------------------------------------
# 5. Modelado
# ---------------------------------------------------------------------------
def train(X, k=K):
    """Paso 12: entrena KMeans con k clusters (random_state=42, n_init=10)."""
    model = KMeans(n_clusters=k, **KMEANS_PARAMS).fit(X)
    print(f"[modelado] KMeans k={k} | inercia={model.inertia_:,.1f}")
    return model


# ---------------------------------------------------------------------------
# 6. Evaluación
# ---------------------------------------------------------------------------
def cluster_profile(user_agg, labels, cols=RFM_COLS):
    """Paso 14: perfil de negocio de cada cluster en valores originales."""
    p = (user_agg[cols].assign(labels=labels)
         .groupby("labels")
         .agg(n=("Recency", "size"),
              Recency=("Recency", "mean"),
              Frequency=("Frequency", "mean"),
              Monetary=("Monetary", "mean"),
              LTV_Profit=("LTV_Profit", "mean"),
              Avg_Odds=("Avg_Odds", "mean"),
              Monetary_tot=("Monetary", "sum"),
              Profit_tot=("LTV_Profit", "sum")))
    p["pct_users"] = p["n"] / p["n"].sum() * 100
    p["pct_profit"] = p["Profit_tot"] / p["Profit_tot"].sum() * 100
    p["margin_%"] = p["Profit_tot"] / p["Monetary_tot"] * 100
    return p.drop(columns=["Monetary_tot", "Profit_tot"]).sort_values("Monetary")


def evaluate(X, model, user_agg):
    """
    Paso 13-14: métricas sobre el 100% de la data (sin muestreo) y perfil de negocio.
    Silhouette con ~108k usuarios tarda alrededor de 45 s.
    """
    labels = model.labels_
    metrics = {
        "k": model.n_clusters,
        "inertia": model.inertia_,
        "silhouette": silhouette_score(X, labels),
        "calinski_harabasz": calinski_harabasz_score(X, labels),
        "davies_bouldin": davies_bouldin_score(X, labels),
    }
    profile = cluster_profile(user_agg, labels)

    print("[evaluación] " + " | ".join(
        f"{k}={v:,.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in metrics.items()))
    return metrics, profile


# ---------------------------------------------------------------------------
# 7. Pipeline completo
# ---------------------------------------------------------------------------
def run_pipeline(path=RAW_DATA_PATH, k=K):
    """Ejecuta todas las etapas en orden y devuelve el modelo entrenado y sus resultados."""
    d = ingest(path)
    d = clean(d)
    user_agg = feature_engineering(d)
    X = preprocess(user_agg)
    model = train(X, k)
    metrics, profile = evaluate(X, model, user_agg)

    segments = user_agg.assign(labels=model.labels_)
    return model, segments, metrics, profile


if __name__ == "__main__":
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 20)

    model, segments, metrics, profile = run_pipeline()
    print("\nPerfil de los clusters:")
    print(profile.round(2))
