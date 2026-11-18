"""Congela (una sola vez) el champion actual como benchmark fijo en s3://<datos>/models/benchmark/.

Copia los archivos del champion (preprocessor.pkl, model.pkl, segment_map.json, manifest.json) y, para poder
comparar contra él sin MLflow, el perfil de clusters de su run y el resumen de métricas por k de esa corrida.
Si ya existe un benchmark, falla: no se sobrescribe (además, la política del bucket bloquea esas escrituras).

    python scripts/freeze_benchmark.py --bucket vantix-<cuenta>-data
"""
from __future__ import annotations

import argparse
import json
import os

import boto3

CHAMPION = "models/champion/"
BENCHMARK = "models/benchmark/"
FILES = ("preprocessor.pkl", "model.pkl", "segment_map.json", "manifest.json")


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--bucket", required=True)
    a = p.parse_args(argv)
    s3 = boto3.Session(profile_name=os.environ.get("AWS_PROFILE")).client("s3")

    if s3.list_objects_v2(Bucket=a.bucket, Prefix=BENCHMARK + "manifest.json").get("KeyCount", 0):
        raise SystemExit(f"s3://{a.bucket}/{BENCHMARK} ya existe: el benchmark se congela una sola vez")

    manifest = json.loads(s3.get_object(Bucket=a.bucket, Key=CHAMPION + "manifest.json")["Body"].read())
    run_id, k, snapshot = manifest["run_id"], manifest["k"], manifest["snapshot_date"]

    # Artefactos de MLflow en S3 (mlflow/<experimento>/<run>/artifacts/…) y salida del paso Train.
    profile = [o["Key"] for page in s3.get_paginator("list_objects_v2").paginate(Bucket=a.bucket, Prefix="mlflow/")
               for o in page.get("Contents", []) if o["Key"].endswith(f"{run_id}/artifacts/profile/cluster_profile_k{k}.csv")]
    if len(profile) != 1:
        raise SystemExit(f"No se encontró un único perfil de clusters del run {run_id}: {profile}")
    extras = {profile[0]: f"cluster_profile_k{k}.csv",
              f"pipelines/training-output/snapshot_date={snapshot}/k_summary.csv": "k_summary.csv"}

    # manifest.json al final: marca el benchmark como completo.
    copies = {CHAMPION + f: f for f in FILES if f != "manifest.json"} | extras | {CHAMPION + "manifest.json": "manifest.json"}
    for src, name in copies.items():
        s3.copy_object(Bucket=a.bucket, Key=BENCHMARK + name, CopySource={"Bucket": a.bucket, "Key": src})
        print(f"s3://{a.bucket}/{src} -> {BENCHMARK}{name}")
    print(f"benchmark congelado: v{manifest['model_version']} (run {run_id}, k={k}, snapshot {snapshot})")


if __name__ == "__main__":
    main()
