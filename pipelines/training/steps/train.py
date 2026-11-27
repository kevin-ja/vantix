"""Paso 5-7 (Training job): preprocesamiento (fit) -> KMeans por k -> evaluación -> MLflow.

MLflow:
  run padre (uno por corrida): lo crea Prepare con la metadata de los datos; Train lo busca por el tag
                               pipeline_execution_id (= --execution-id), sigue en él y agrega git_commit y k_min/k_max
  run hijo  (uno por k):       k, métricas, perfil de clusters, preprocessor.pkl y model (KMeans)

SageMaker:  canal SM_CHANNEL_FEATURES, --execution-id, MLFLOW_TRACKING_URI (URL del servidor propio) y
            MLFLOW_TRACKING_PASSWORD_PARAM (parámetro SSM con la contraseña; ver pipelines/common/mlflow_auth.py).
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import argparse  # noqa: E402
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
from pipelines.common.mlflow_auth import configure_credentials  # noqa: E402
from pipelines.common.transformers import build_preprocessor  # noqa: E402
from pipelines.training.evaluation import cluster_profile, clustering_metrics  # noqa: E402
from pipelines.training.steps.prepare import EXECUTION_TAG  # noqa: E402

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
    p.add_argument("--execution-id", required=True, help="Id de la ejecución del pipeline (une Prepare y Train)")
    p.add_argument("--model-dir", default=os.environ.get("SM_MODEL_DIR", ".local/model"))
    p.add_argument("--tracking-uri", default=os.environ.get("MLFLOW_TRACKING_URI"))
    p.add_argument("--experiment", default=EXPERIMENT)
    p.add_argument("--k-min", type=int, default=2)
    p.add_argument("--k-max", type=int, default=10)
    p.add_argument("--random-state", type=int, default=42)
    p.add_argument("--n-init", type=int, default=10)
    p.add_argument("--git-commit", default=os.environ.get("GIT_COMMIT", "unknown"))
    return p.parse_args(argv)


def find_parent_run(experiment: str, execution_id: str) -> str:
    """Run padre que creó Prepare en esta misma ejecución del pipeline."""
    exp = mlflow.get_experiment_by_name(experiment)
    runs = [] if exp is None else mlflow.search_runs(
        [exp.experiment_id], filter_string=f"tags.{EXECUTION_TAG} = '{execution_id}'", output_format="list")
    if len(runs) != 1:
        raise RuntimeError(f"Se esperaba 1 run de Prepare con {EXECUTION_TAG}={execution_id} y hay {len(runs)}")
    return runs[0].info.run_id


def main(argv=None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    a = parse_args(argv)
    if not a.tracking_uri:
        raise ValueError("Falta --tracking-uri o MLFLOW_TRACKING_URI")

    features = pd.read_parquet(resolve_input(a.features_dir))
    X = features[FEATURE_COLS]

    # 5. Preprocesamiento: se ajusta una sola vez (no depende de k).
    preprocessor = build_preprocessor()
    Xt = preprocessor.fit_transform(X)
    log.info("matriz de entrenamiento %s", Xt.shape)

    configure_credentials(a.tracking_uri)
    mlflow.set_tracking_uri(a.tracking_uri)
    mlflow.set_experiment(a.experiment)
    parent_id = find_parent_run(a.experiment, a.execution_id)
    snapshot_date = mlflow.get_run(parent_id).data.params["snapshot_date"]

    tmp = Path(tempfile.mkdtemp())
    pre_path = tmp / "preprocessor.pkl"
    joblib.dump(preprocessor, pre_path)

    summary = []
    with mlflow.start_run(run_id=parent_id) as parent:   # el de Prepare: ya tiene la metadata de los datos
        mlflow.log_params({
            "git_commit": a.git_commit,
            "k_min": a.k_min,
            "k_max": a.k_max,
            "random_state": a.random_state,
            "n_init": a.n_init,
        })
        mlflow.set_tag("git_commit", a.git_commit)

        # 6-7. KMeans por k + evaluación con el 100 % de las observaciones.
        for k in range(a.k_min, a.k_max + 1):
            with mlflow.start_run(run_name=f"k={k}", nested=True) as child:
                t0 = time.time()
                model = KMeans(n_clusters=k, random_state=a.random_state, n_init=a.n_init).fit(Xt)
                metrics = clustering_metrics(Xt, model.labels_, model.inertia_)
                profile = cluster_profile(features, model.labels_)

                mlflow.log_params({"k": k, "snapshot_date": snapshot_date,
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
