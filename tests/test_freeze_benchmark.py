"""scripts/freeze_benchmark.py: el perfil de clusters sale de MLflow (no de s3://<datos>/mlflow/)."""
from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path

import mlflow
import pytest
from mlflow.exceptions import MlflowException

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("freeze_benchmark", ROOT / "scripts" / "freeze_benchmark.py")
freeze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(freeze)


class FakeS3:
    def __init__(self, objects: dict[str, bytes]):
        self.objects = dict(objects)

    def list_objects_v2(self, Bucket, Prefix):
        return {"KeyCount": sum(k.startswith(Prefix) for k in self.objects)}

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key])}

    def upload_file(self, Filename, Bucket, Key):
        self.objects[Key] = Path(Filename).read_bytes()

    def copy_object(self, Bucket, Key, CopySource):
        self.objects[Key] = self.objects[CopySource["Key"]]


@pytest.fixture
def mlflow_run(tmp_path):
    uri = f"sqlite:///{tmp_path / 'mlflow.db'}"
    mlflow.set_tracking_uri(uri)
    exp = mlflow.create_experiment("t", artifact_location=str(tmp_path / "artifacts"))
    with mlflow.start_run(experiment_id=exp) as run:
        prof = tmp_path / "cluster_profile_k5.csv"
        prof.write_text("cluster,pct_users\n0,1.0\n")
        mlflow.log_artifact(str(prof), "profile")
    return uri, run.info.run_id


def champion(run_id: str) -> dict[str, bytes]:
    manifest = {"model_version": "1", "run_id": run_id, "k": 5, "snapshot_date": "2025-04-30"}
    objs = {f"models/champion/{f}": f.encode() for f in ("preprocessor.pkl", "model.pkl", "segment_map.json")}
    objs["models/champion/manifest.json"] = json.dumps(manifest).encode()
    objs["pipelines/training-output/snapshot_date=2025-04-30/k_summary.csv"] = b"k\n5\n"
    return objs


def run(monkeypatch, s3, uri):
    monkeypatch.setattr(freeze.boto3, "Session", lambda **_: type("S", (), {"client": lambda self, _: s3})())
    freeze.main(["--bucket", "b", "--tracking-uri", uri])


def test_congela_con_el_perfil_de_mlflow(monkeypatch, mlflow_run):
    uri, run_id = mlflow_run
    s3 = FakeS3(champion(run_id))
    run(monkeypatch, s3, uri)
    bench = {k.removeprefix("models/benchmark/"): v for k, v in s3.objects.items() if k.startswith("models/benchmark/")}
    assert set(bench) == {"preprocessor.pkl", "model.pkl", "segment_map.json", "manifest.json",
                          "cluster_profile_k5.csv", "k_summary.csv"}
    assert bench["cluster_profile_k5.csv"] == b"cluster,pct_users\n0,1.0\n"
    assert list(s3.objects)[-1] == "models/benchmark/manifest.json"  # el manifest marca el final


def test_no_sobrescribe(monkeypatch, mlflow_run):
    uri, run_id = mlflow_run
    s3 = FakeS3(champion(run_id) | {"models/benchmark/manifest.json": b"{}"})
    with pytest.raises(SystemExit, match="una sola vez"):
        run(monkeypatch, s3, uri)


def test_sin_perfil_en_mlflow_no_escribe_nada(monkeypatch, mlflow_run):
    uri, _ = mlflow_run
    s3 = FakeS3(champion("run-inexistente"))
    with pytest.raises(MlflowException):
        run(monkeypatch, s3, uri)
    assert not any(k.startswith("models/benchmark/") for k in s3.objects)
