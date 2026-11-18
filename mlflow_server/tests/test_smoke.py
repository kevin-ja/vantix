"""Test de humo del servidor en AWS.

Lee MLFLOW_TRACKING_URI, MLFLOW_TRACKING_USERNAME y MLFLOW_TRACKING_PASSWORD.

  test_auth_required     sin credenciales el servidor rechaza (401)
  test_round_trip        experimento → run (params, métricas) → artefacto subido y descargado (proxy a S3)
                         → versión del Model Registry con alias
  test_state_persisted   lo escrito por test_round_trip sigue ahí. Se corre DESPUÉS de destruir el servidor
                         y su disco: prueba que el estado se restaura desde S3 (make recreate-test).
"""
from __future__ import annotations

import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

import mlflow
import pytest
from mlflow.tracking import MlflowClient

EXPERIMENT = "smoke-test"
MODEL = "smoke-test-model"
CONTENT = "mlflow smoke test"


@pytest.fixture(scope="module")
def client() -> MlflowClient:
    for var in ("MLFLOW_TRACKING_URI", "MLFLOW_TRACKING_USERNAME", "MLFLOW_TRACKING_PASSWORD"):
        if not os.environ.get(var):
            pytest.exit(f"Falta {var}")
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    return MlflowClient()


def test_auth_required(client):
    url = os.environ["MLFLOW_TRACKING_URI"].rstrip("/") + "/api/2.0/mlflow/experiments/search?max_results=1"
    with pytest.raises(urllib.error.HTTPError) as err:
        urllib.request.urlopen(url, timeout=15)
    assert err.value.code == 401


def test_round_trip(client):
    mlflow.set_experiment(EXPERIMENT)
    with mlflow.start_run() as run, tempfile.TemporaryDirectory() as tmp:
        mlflow.log_param("check", "round-trip")
        mlflow.log_metric("score", 0.99)
        f = Path(tmp) / "model" / "artifact.txt"
        f.parent.mkdir()
        f.write_text(CONTENT)
        mlflow.log_artifacts(str(f.parent), "model")

    run_id = run.info.run_id
    with tempfile.TemporaryDirectory() as tmp:
        got = Path(mlflow.artifacts.download_artifacts(run_id=run_id, artifact_path="model/artifact.txt", dst_path=tmp))
        assert got.read_text() == CONTENT

    try:
        client.create_registered_model(MODEL)
    except mlflow.exceptions.MlflowException as e:
        if "RESOURCE_ALREADY_EXISTS" not in str(e):
            raise
    mv = client.create_model_version(MODEL, f"runs:/{run_id}/model", run_id=run_id)
    client.set_registered_model_alias(MODEL, "smoke", mv.version)
    assert client.get_model_version_by_alias(MODEL, "smoke").run_id == run_id
    assert client.get_run(run_id).info.status == "FINISHED"


def test_state_persisted(client):
    exp = client.get_experiment_by_name(EXPERIMENT)
    assert exp is not None, "El experimento no sobrevivió: el estado no se restauró desde S3"
    runs = client.search_runs([exp.experiment_id], max_results=1)
    assert runs, "No hay runs: el estado no se restauró desde S3"
    alias = client.get_model_version_by_alias(MODEL, "smoke")
    with tempfile.TemporaryDirectory() as tmp:
        got = Path(mlflow.artifacts.download_artifacts(run_id=alias.run_id, artifact_path="model/artifact.txt",
                                                       dst_path=tmp))
        assert got.read_text() == CONTENT
