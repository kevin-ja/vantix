import json

import joblib
import numpy as np
import pandas as pd
import pytest
from sklearn.cluster import KMeans

from pipelines.common.champion import load_champion
from pipelines.common.config import FEATURE_COLS
from pipelines.common.transformers import build_preprocessor
from pipelines.inference.steps import score

K = 2


def fit_artifacts(seed: int = 0):
    rng = np.random.default_rng(seed)
    X = pd.DataFrame(rng.gamma(2.0, 10.0, size=(60, len(FEATURE_COLS))), columns=FEATURE_COLS)
    pre = build_preprocessor()
    model = KMeans(n_clusters=K, random_state=0, n_init=3).fit(pre.fit_transform(X))
    return pre, model


def write_champion(d, pre, model, k=K, seg_map=None):
    d.mkdir(parents=True, exist_ok=True)
    joblib.dump(pre, d / "preprocessor.pkl")
    joblib.dump(model, d / "model.pkl")
    (d / "segment_map.json").write_text(json.dumps(seg_map or {str(i): f"seg{i}" for i in range(k)}))
    (d / "manifest.json").write_text(json.dumps({"model_version": "7", "run_id": "abc", "k": k,
                                                       "git_commit": "train123"}))
    return d


@pytest.fixture
def champion_dir(tmp_path):
    return write_champion(tmp_path / "champion", *fit_artifacts())


@pytest.fixture
def raw_uri(tmp_path, raw_df):
    for ingest in ("2025-04-15", "2025-04-30"):
        part = tmp_path / "raw" / f"ingest_date={ingest}"
        part.mkdir(parents=True)
        raw_df.to_parquet(part / "data.parquet", index=False)
    return str(tmp_path / "raw")


def test_score_end_to_end(tmp_path, raw_uri, champion_dir, monkeypatch):
    monkeypatch.setenv("GIT_COMMIT", "infer456")
    out = tmp_path / "scores"
    score.main(["--raw-uri", raw_uri, "--champion-uri", str(champion_dir), "--output-uri", str(out),
                "--snapshot-date", "2025-04-30", "--scoring-date", "2025-05-01"])

    part = out / "scoring_date=2025-05-01"
    df = pd.read_parquet(part / "scores.parquet")
    assert list(df.columns) == score.OUTPUT_COLS
    assert sorted(df["customer_id"]) == ["u1", "u2", "u3"]
    assert df["cluster_id"].between(0, K - 1).all()
    assert (df["segment_name"] == "seg" + df["cluster_id"].astype(str)).all()
    assert (df["model_version"] == "7").all()

    latest = json.loads((out / "latest.json").read_text())
    assert latest["path"] == str(part / "scores.parquet")
    assert latest["rows"] == 3
    summary = json.loads((part / "summary.json").read_text())
    assert summary["ingest_date"] == "2025-04-30"  # "auto" -> última partición
    assert sum(s["n"] for s in summary["segments"].values()) == 3
    assert summary["training_git_commit"] == "train123"  # del manifest del champion
    assert summary["inference_git_commit"] == "infer456"  # de GIT_COMMIT (lo pone el pipeline)


def test_score_is_deterministic(tmp_path, raw_uri, champion_dir):
    for run in ("a", "b"):
        score.main(["--raw-uri", raw_uri, "--champion-uri", str(champion_dir), "--output-uri",
                    str(tmp_path / run), "--snapshot-date", "2025-04-30", "--scoring-date", "2025-05-01"])
    a, b = (pd.read_parquet(tmp_path / r / "scoring_date=2025-05-01" / "scores.parquet") for r in ("a", "b"))
    pd.testing.assert_frame_equal(a, b)


def test_auto_dates(raw_uri):
    ingest, snapshot, scoring = score.resolve_dates("auto", "auto", "2025-05-01", raw_uri)
    assert (ingest, snapshot, scoring) == ("2025-04-30", "2025-04-30", "2025-05-01")


def test_stale_batch_fails(raw_df):
    with pytest.raises(ValueError, match="desactualizados"):
        score.check_coverage(raw_df, "2025-05-07")


def test_inconsistent_champion_fails(tmp_path):
    pre, model = fit_artifacts()
    d = write_champion(tmp_path / "bad", pre, model, seg_map={"0": "a", "1": "b", "2": "c"})
    with pytest.raises(ValueError, match="inconsistentes"):
        load_champion(d)


def test_missing_artifact_fails(champion_dir):
    (champion_dir / "model.pkl").unlink()
    with pytest.raises(FileNotFoundError):
        load_champion(champion_dir)


def test_promote_exports_champion(tmp_path):
    mlflow = pytest.importorskip("mlflow")
    from pipelines.training import promote
    from pipelines.training.steps.model_training import log_sklearn_model

    uri = f"sqlite:///{tmp_path / 'mlflow.db'}"
    mlflow.set_tracking_uri(uri)
    mlflow.set_experiment("t")
    pre, model = fit_artifacts()
    joblib.dump(pre, tmp_path / "preprocessor.pkl")
    with mlflow.start_run() as run:
        mlflow.log_params({"k": K, "snapshot_date": "2025-04-30", "git_commit": "x"})
        mlflow.log_artifact(str(tmp_path / "preprocessor.pkl"), "preprocessor")
        log_sklearn_model(model, "model")

    seg = tmp_path / "segment_map.json"
    seg.write_text(json.dumps({"0": "VIP", "1": "Dormido"}))
    export = tmp_path / "models" / "champion"
    base = ["--tracking-uri", uri, "--export-uri", str(export), "--promoted-by", "ana"]
    with pytest.raises(SystemExit):  # sin --reason no se promueve
        promote.main(base + ["--run-id", run.info.run_id, "--segment-map", str(seg)])
    for _ in range(2):  # v1 y v2 del mismo run
        promote.main(base + ["--run-id", run.info.run_id, "--segment-map", str(seg), "--reason", "ok"])

    champ = load_champion(export)
    assert champ.manifest["run_id"] == run.info.run_id
    assert champ.manifest["model_version"] == "2"
    assert champ.segment_map == {0: "VIP", 1: "Dormido"}
    np.testing.assert_array_equal(champ.model.cluster_centers_, model.cluster_centers_)

    client = mlflow.tracking.MlflowClient()
    tags = client.get_model_version(promote.MODEL_NAME, "2").tags
    assert (tags["action"], tags["promoted_by"], tags["reason"]) == ("promote", "ana", "ok")
    assert tags["segment_map"] == str(seg)

    # rollback: @champion vuelve a v1 y se re-exporta
    promote.main(base + ["--version", "1", "--reason", "v2 mala"])
    assert load_champion(export).manifest["model_version"] == "1"
    assert client.get_model_version(promote.MODEL_NAME, "1").tags["action"] == "rollback"
