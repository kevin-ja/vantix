"""Congela (una sola vez) el champion actual como benchmark fijo en s3://<datos>/models/benchmark/.

Copia los archivos del champion (preprocessor.pkl, model.pkl, segment_map.json, manifest.json) y, para poder
comparar contra él sin MLflow, el perfil de clusters de su run (se descarga de MLflow: el servidor debe estar
encendido) y el resumen de métricas por k de esa corrida.
Si ya existe un benchmark, falla: no se sobrescribe (además, la política del bucket bloquea esas escrituras).

    make benchmark-freeze   (pasa MLFLOW_TRACKING_URI, MLFLOW_TRACKING_PASSWORD_PARAM y --bucket)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

import boto3
from mlflow.tracking import MlflowClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipelines.common.mlflow_auth import configure_credentials  # noqa: E402

CHAMPION = "models/champion/"
BENCHMARK = "models/benchmark/"
FILES = ("preprocessor.pkl", "model.pkl", "segment_map.json", "manifest.json")


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--bucket", required=True)
    p.add_argument("--tracking-uri", default=os.environ.get("MLFLOW_TRACKING_URI"))
    a = p.parse_args(argv)
    if not a.tracking_uri:
        p.error("falta --tracking-uri (o MLFLOW_TRACKING_URI)")
    s3 = boto3.Session(profile_name=os.environ.get("AWS_PROFILE")).client("s3")

    if s3.list_objects_v2(Bucket=a.bucket, Prefix=BENCHMARK + "manifest.json").get("KeyCount", 0):
        raise SystemExit(f"s3://{a.bucket}/{BENCHMARK} ya existe: el benchmark se congela una sola vez")

    manifest = json.loads(s3.get_object(Bucket=a.bucket, Key=CHAMPION + "manifest.json")["Body"].read())
    run_id, k, snapshot = manifest["run_id"], manifest["k"], manifest["snapshot_date"]

    # Perfil de clusters: artefacto del run en MLflow (el servidor propio lo guarda en su bucket, no en este).
    configure_credentials(a.tracking_uri)
    client = MlflowClient(tracking_uri=a.tracking_uri)
    tmp = Path(tempfile.mkdtemp())
    profile = client.download_artifacts(run_id, f"profile/cluster_profile_k{k}.csv", str(tmp))
    s3.upload_file(profile, a.bucket, BENCHMARK + f"cluster_profile_k{k}.csv")
    print(f"MLflow run {run_id}: profile/cluster_profile_k{k}.csv -> {BENCHMARK}cluster_profile_k{k}.csv")
    extras = {f"pipelines/training-output/snapshot_date={snapshot}/k_summary.csv": "k_summary.csv"}

    # manifest.json al final: marca el benchmark como completo.
    copies = {CHAMPION + f: f for f in FILES if f != "manifest.json"} | extras
    copies[CHAMPION + "manifest.json"] = "manifest.json"
    for src, name in copies.items():
        s3.copy_object(Bucket=a.bucket, Key=BENCHMARK + name, CopySource={"Bucket": a.bucket, "Key": src})
        print(f"s3://{a.bucket}/{src} -> {BENCHMARK}{name}")
    print(f"benchmark congelado: v{manifest['model_version']} (run {run_id}, k={k}, snapshot {snapshot})")


if __name__ == "__main__":
    main()
