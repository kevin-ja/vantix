"""Paso 5-7 (Training job): preprocesamiento (fit) -> KMeans por k -> evaluación -> MLflow.

MLflow:
  run padre (uno por corrida): snapshot_date, window_days, git_commit, hashes de datos
  run hijo  (uno por k):       k, métricas, perfil de clusters, preprocessor.pkl y model (KMeans)

Local:      python -m pipelines.training.steps.train --features-dir .local/prepare/features \
                --metadata-dir .local/prepare/metadata --tracking-uri sqlite:///.local/mlflow.db
SageMaker:  canales SM_CHANNEL_FEATURES / SM_CHANNEL_METADATA y MLFLOW_TRACKING_URI (ARN del servidor).
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import argparse  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import os  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402

import joblib  # noqa: E402
import mlflow  # noqa: E402
import mlflow.sklearn  # noqa: E402
import pandas as pd  # noqa: E402
from sklearn.cluster import KMeans  # noqa: E402

from pipelines.common.config import FEATURE_COLS  # noqa: E402
from pipelines.common.io import resolve_input  # noqa: E402
from pipelines.common.transformers import build_preprocessor  # noqa: E402
from pipelines.training.evaluation import cluster_profile, clustering_metrics  # noqa: E402

log = logging.getLogger("train")
EXPERIMENT = "vantix-segmentation"


def log_sklearn_model(model, name: str) -> None:
    """MLflow 3 usa `name`; MLflow 2.x, `artifact_path` (el contenedor puede traer cualquiera)."""
    try:
        mlflow.sklearn.log_model(model, name=name)
    except TypeError:
        mlflow.sklearn.log_model(model, artifact_path=name)


def parse_args(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--features-dir", default=os.environ.get("SM_CHANNEL_FEATURES"))
    p.add_argument("--metadata-dir", default=os.environ.get("SM_CHANNEL_METADATA"))
    p.add_argument("--model-dir", default=os.environ.get("SM_MODEL_DIR", ".local/model"))
    p.add_argument("--tracking-uri", default=os.environ.get("MLFLOW_TRACKING_URI"))
    p.add_argument("--experiment", default=EXPERIMENT)
    p.add_argument("--k-min", type=int, default=2)
    p.add_argument("--k-max", type=int, default=10)
    p.add_argument("--random-state", type=int, default=42)
    p.add_argument("--n-init", type=int, default=10)
    p.add_argument("--git-commit", default=os.environ.get("GIT_COMMIT", "unknown"))
    return p.parse_args(argv)


def main(argv=None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    a = parse_args(argv)
    if not a.tracking_uri:
        raise ValueError("Falta --tracking-uri o MLFLOW_TRACKING_URI")

    features = pd.read_parquet(resolve_input(a.features_dir))
    metadata = json.loads((Path(a.metadata_dir) / "metadata.json").read_text())
    X = features[FEATURE_COLS]

    # 5. Preprocesamiento: se ajusta una sola vez (no depende de k).
    preprocessor = build_preprocessor()
    Xt = preprocessor.fit_transform(X)
    log.info("matriz de entrenamiento %s", Xt.shape)

    mlflow.set_tracking_uri(a.tracking_uri)
    mlflow.set_experiment(a.experiment)

    tmp = Path(tempfile.mkdtemp())
    pre_path = tmp / "preprocessor.pkl"
    joblib.dump(preprocessor, pre_path)

    summary = []
    run_name = f"snapshot={metadata['snapshot_date']}"
    with mlflow.start_run(run_name=run_name) as parent:
        mlflow.log_params({
            "snapshot_date": metadata["snapshot_date"],
            "window_days": metadata["window_days"],
            "git_commit": a.git_commit,
            "k_min": a.k_min,
            "k_max": a.k_max,
            "random_state": a.random_state,
            "n_init": a.n_init,
            "n_users": metadata["n_users"],
            "raw_uri": metadata["raw_uri"],
            "raw_sha256": metadata["raw_sha256"],
            "features_sha256": metadata["features_sha256"],
        })
        mlflow.set_tag("git_commit", a.git_commit)
        mlflow.log_dict(metadata, "data/metadata.json")

        # 6-7. KMeans por k + evaluación con el 100 % de las observaciones.
        for k in range(a.k_min, a.k_max + 1):
            with mlflow.start_run(run_name=f"k={k}", nested=True) as child:
                t0 = time.time()
                model = KMeans(n_clusters=k, random_state=a.random_state, n_init=a.n_init).fit(Xt)
                metrics = clustering_metrics(Xt, model.labels_, model.inertia_)
                profile = cluster_profile(features, model.labels_)

                mlflow.log_params({"k": k, "snapshot_date": metadata["snapshot_date"],
                                   "git_commit": a.git_commit})
                mlflow.set_tag("git_commit", a.git_commit)
                mlflow.log_metrics({**metrics, "min_cluster_pct": float(profile["pct_users"].min()),
                                    "fit_eval_seconds": time.time() - t0})

                prof_path = tmp / f"cluster_profile_k{k}.csv"
                profile.round(4).to_csv(prof_path, index=False)
                mlflow.log_artifact(str(prof_path), "profile")
                mlflow.log_artifact(str(pre_path), "preprocessor")
                log_sklearn_model(model, "model")

                summary.append({"k": k, "run_id": child.info.run_id, **metrics})
                log.info("k=%d | %s", k, " | ".join(f"{m}={v:,.4f}" for m, v in metrics.items()))

        summary_df = pd.DataFrame(summary)
        sum_path = tmp / "k_summary.csv"
        summary_df.to_csv(sum_path, index=False)
        mlflow.log_artifact(str(sum_path))

    Path(a.model_dir).mkdir(parents=True, exist_ok=True)
    summary_df.to_csv(Path(a.model_dir) / "k_summary.csv", index=False)
    log.info("run padre %s\n%s", parent.info.run_id, summary_df.to_string(index=False))


if __name__ == "__main__":
    main()
