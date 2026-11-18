import sys
import types

import pytest

from pipelines.common.mlflow_auth import configure_credentials

VARS = ("MLFLOW_TRACKING_USERNAME", "MLFLOW_TRACKING_PASSWORD", "MLFLOW_TRACKING_PASSWORD_PARAM")


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    for v in VARS:
        monkeypatch.delenv(v, raising=False)


def fake_boto3(monkeypatch, value="s3cr3t"):
    calls = []

    class SSM:
        def get_parameter(self, Name, WithDecryption):
            calls.append((Name, WithDecryption))
            return {"Parameter": {"Value": value}}

    class Session:
        def __init__(self, **_):
            pass

        def client(self, name):
            assert name == "ssm"
            return SSM()

    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(Session=Session))
    return calls


def test_local_uri_needs_no_credentials(monkeypatch):
    configure_credentials("sqlite:///x.db")
    assert "MLFLOW_TRACKING_USERNAME" not in __import__("os").environ


def test_password_read_from_ssm(monkeypatch):
    calls = fake_boto3(monkeypatch)
    monkeypatch.setenv("MLFLOW_TRACKING_PASSWORD_PARAM", "/vantix-mlflow/admin-password")
    configure_credentials("https://mlflow.example")
    import os
    assert os.environ["MLFLOW_TRACKING_USERNAME"] == "admin"
    assert os.environ["MLFLOW_TRACKING_PASSWORD"] == "s3cr3t"
    assert calls == [("/vantix-mlflow/admin-password", True)]


def test_existing_password_is_not_overwritten(monkeypatch):
    calls = fake_boto3(monkeypatch)
    monkeypatch.setenv("MLFLOW_TRACKING_PASSWORD_PARAM", "/p")
    monkeypatch.setenv("MLFLOW_TRACKING_PASSWORD", "ya")
    configure_credentials("https://mlflow.example")
    import os
    assert os.environ["MLFLOW_TRACKING_PASSWORD"] == "ya"
    assert calls == []
