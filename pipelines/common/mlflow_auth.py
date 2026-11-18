"""Credenciales del servidor de MLflow propio (basic auth; ver mlflow_server/).

MLflow lee MLFLOW_TRACKING_USERNAME / MLFLOW_TRACKING_PASSWORD del entorno. Para no poner la contraseña en
variables visibles (definición del job de SageMaker, logs de CI), se pasa el NOMBRE del parámetro de SSM en
MLFLOW_TRACKING_PASSWORD_PARAM y aquí se lee con el rol de quien ejecuta.
"""
from __future__ import annotations

import os

DEFAULT_USERNAME = "admin"


def configure_credentials(tracking_uri: str | None) -> None:
    """Completa usuario/contraseña desde SSM si el servidor es http(s) y aún no están en el entorno."""
    if not tracking_uri or not tracking_uri.startswith(("http://", "https://")):
        return  # sqlite local, etc.: sin auth
    os.environ.setdefault("MLFLOW_TRACKING_USERNAME", DEFAULT_USERNAME)
    param = os.environ.get("MLFLOW_TRACKING_PASSWORD_PARAM")
    if os.environ.get("MLFLOW_TRACKING_PASSWORD") or not param:
        return
    import boto3  # solo hace falta en este camino

    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    ssm = boto3.Session(profile_name=os.environ.get("AWS_PROFILE"), region_name=region).client("ssm")
    value = ssm.get_parameter(Name=param, WithDecryption=True)["Parameter"]["Value"]
    os.environ["MLFLOW_TRACKING_PASSWORD"] = value
