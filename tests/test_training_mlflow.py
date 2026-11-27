"""data_processing crea el run padre en MLflow con la metadata de los datos; model_training lo encuentra por el
id de ejecución del pipeline."""
from __future__ import annotations

import mlflow
import pytest

from pipelines.training.steps import data_processing, model_training


@pytest.fixture
def tracking(tmp_path, monkeypatch):
    uri = f"sqlite:///{tmp_path / 'mlflow.db'}"
    monkeypatch.setenv("MLFLOW_TRACKING_URI", uri)
    mlflow.set_tracking_uri(uri)
    mlflow.create_experiment(data_processing.EXPERIMENT, artifact_location=str(tmp_path / "artifacts"))
    return uri


def run_data_processing(tmp_path, raw_df, execution_id):
    raw = tmp_path / "raw.parquet"
    raw_df.to_parquet(raw, index=False)
    out = tmp_path / f"out-{execution_id}"
    data_processing.main(["--input", str(raw), "--output-dir", str(out), "--snapshot-date", "2025-04-30",
                          "--raw-uri", "s3://b/raw/ingest_date=2025-04-30/", "--execution-id", execution_id])
    return out


def runs():
    exp = mlflow.get_experiment_by_name(data_processing.EXPERIMENT)
    return mlflow.search_runs([exp.experiment_id], output_format="list")


def test_data_processing_y_model_training_comparten_el_run_padre(tmp_path, raw_df, tracking):
    out = run_data_processing(tmp_path, raw_df, "exec-1")
    assert not (out / "metadata").exists()  # la metadata ya no viaja por S3

    (parent,) = runs()
    assert parent.data.tags[data_processing.EXECUTION_TAG] == "exec-1"
    assert parent.data.params["raw_uri"] == "s3://b/raw/ingest_date=2025-04-30/"
    assert parent.data.params["n_users"] == "3" and len(parent.data.params["raw_sha256"]) == 64
    assert [d.dataset.name for d in parent.inputs.dataset_inputs] == ["user_features"]

    model_training.main(["--features-dir", str(out / "features"),
                         "--execution-id", "exec-1", "--k-min", "2", "--k-max", "2", "--git-commit", "abc123"])

    all_runs = {r.info.run_id: r for r in runs()}
    parent = all_runs[parent.info.run_id]
    children = [r for r in all_runs.values() if r.data.tags.get("mlflow.parentRunId") == parent.info.run_id]
    assert len(all_runs) == 2 and len(children) == 1  # model_training no crea otro run padre
    assert parent.info.status == "FINISHED"
    assert parent.data.params["git_commit"] == "abc123" and parent.data.params["k_min"] == "2"
    assert children[0].data.params["snapshot_date"] == "2025-04-30"


def test_model_training_sin_run_de_data_processing_falla(tmp_path, raw_df, tracking):
    out = run_data_processing(tmp_path, raw_df, "exec-1")
    with pytest.raises(RuntimeError, match="exec-2"):
        model_training.main(["--features-dir", str(out / "features"),
                             "--execution-id", "exec-2", "--k-min", "2", "--k-max", "2"])
