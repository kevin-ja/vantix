"""Paso 8 (manual): registra el run hijo elegido como @champion y lo exporta para la inferencia.

La decisión la toma un especialista (docs/arch_mlops.md §5); este script solo la ejecuta y la deja auditada.

    # promover + exportar
    python -m pipelines.training.promote --run-id <run hijo> --segment-map segment_maps/2025-04-30_k5.json \
        --reason "k=5, perfiles estables vs benchmark" --export-uri s3://<datos>/models/champion
    # rollback: @champion vuelve a una versión anterior del registry y se re-exporta
    python -m pipelines.training.promote --version 1 --reason "v2 segmenta mal" --export-uri s3://<datos>/models/champion
    # solo re-exportar el @champion actual
    python -m pipelines.training.promote --export-only --export-uri s3://<datos>/models/champion

segment_map: {"0": "VIP", "1": "Dormido", ...} con una entrada por cluster del k elegido; se versiona por PR en
segment_maps/<snapshot_date>_k<k>.json.
Cada promoción o rollback etiqueta la versión con promoted_by, reason y segment_map (auditoría).

La exportación deja en --export-uri (local o s3://) los archivos que lee la inferencia, todos del mismo run:
preprocessor.pkl, model.pkl, segment_map.json y manifest.json. Así la inferencia no necesita MLflow encendido.
"""
from __future__ import annotations

import argparse
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import joblib
import mlflow
import mlflow.sklearn
from mlflow.tracking import MlflowClient

from pipelines.common import storage
from pipelines.common.champion import (
    CHAMPION_FILES,
    MANIFEST_FILE,
    MODEL_FILE,
    PREPROCESSOR_FILE,
    SEGMENT_MAP_FILE,
    load_champion,
)

MODEL_NAME = "vantix-segmentation"
ALIAS = "champion"


def tag_decision(client: MlflowClient, version: str, action: str, promoted_by: str, reason: str) -> None:
    """Auditoría: quién, por qué y qué acción dejó esta versión como @champion."""
    for key, value in {"action": action, "promoted_by": promoted_by, "reason": reason,
                       "promoted_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}.items():
        client.set_model_version_tag(MODEL_NAME, version, key, value)


def register(client: MlflowClient, run_id: str, segment_map_path: str, promoted_by: str, reason: str) -> str:
    run = client.get_run(run_id)
    k = int(run.data.params["k"])
    seg_map = json.loads(Path(segment_map_path).read_text())
    if sorted(int(c) for c in seg_map) != list(range(k)):
        raise ValueError(f"segment_map debe tener exactamente los clusters 0..{k - 1}")
    if len(set(seg_map.values())) != k:
        raise ValueError("Nombres de segmento repetidos")

    # Siempre como segment_map/segment_map.json, junto a preprocessor.pkl y el modelo, en el mismo run.
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, SEGMENT_MAP_FILE)
        with open(path, "w") as f:
            json.dump(seg_map, f, indent=2, ensure_ascii=False)
        client.log_artifact(run_id, path, "segment_map")

    version = mlflow.register_model(f"runs:/{run_id}/model", MODEL_NAME)
    client.set_registered_model_alias(MODEL_NAME, ALIAS, version.version)
    client.set_model_version_tag(MODEL_NAME, version.version, "k", str(k))
    client.set_model_version_tag(MODEL_NAME, version.version, "snapshot_date", run.data.params["snapshot_date"])
    client.set_model_version_tag(MODEL_NAME, version.version, "segment_map", segment_map_path)
    tag_decision(client, version.version, "promote", promoted_by, reason)
    print(f"{MODEL_NAME} v{version.version} -> @{ALIAS} (run {run_id}, k={k})")
    return version.version


def rollback(client: MlflowClient, version: str, promoted_by: str, reason: str) -> str:
    """Reasigna @champion a una versión ya registrada (sus artefactos y segment_map no cambian)."""
    client.get_model_version(MODEL_NAME, version)  # falla si no existe
    client.set_registered_model_alias(MODEL_NAME, ALIAS, version)
    tag_decision(client, version, "rollback", promoted_by, reason)
    print(f"{MODEL_NAME} v{version} -> @{ALIAS} (rollback)")
    return version


def export_champion(client: MlflowClient, export_uri: str) -> dict:
    """Copia los artefactos del @champion actual a export_uri (local o s3://)."""
    mv = client.get_model_version_by_alias(MODEL_NAME, ALIAS)
    run = client.get_run(mv.run_id)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        out = tmp / "champion"
        out.mkdir()
        pre = client.download_artifacts(mv.run_id, f"preprocessor/{PREPROCESSOR_FILE}", str(tmp))
        seg = client.download_artifacts(mv.run_id, f"segment_map/{SEGMENT_MAP_FILE}", str(tmp))
        os.replace(pre, out / PREPROCESSOR_FILE)
        os.replace(seg, out / SEGMENT_MAP_FILE)
        # El modelo se guarda con joblib: la inferencia lo carga sin MLflow.
        joblib.dump(mlflow.sklearn.load_model(f"models:/{MODEL_NAME}/{mv.version}"), out / MODEL_FILE)

        manifest = {
            "model_name": MODEL_NAME,
            "model_version": str(mv.version),
            "run_id": mv.run_id,
            "k": int(run.data.params["k"]),
            "snapshot_date": run.data.params["snapshot_date"],
            "git_commit": run.data.params.get("git_commit", "unknown"),
            "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        (out / MANIFEST_FILE).write_text(json.dumps(manifest, indent=2))

        load_champion(out)  # verifica que el paquete es coherente antes de publicarlo
        # manifest.json al final: si algo falla a mitad, el manifest viejo no apunta a archivos nuevos.
        for name in CHAMPION_FILES:
            storage.upload_file(out / name, storage.join(export_uri, name))

    print(f"champion v{manifest['model_version']} (k={manifest['k']}) exportado a {export_uri}")
    return manifest


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--run-id")
    p.add_argument("--segment-map")
    p.add_argument("--export-uri", default=os.environ.get("VANTIX_CHAMPION_URI"),
                   help="Destino de models/champion/ (local o s3://)")
    p.add_argument("--version", help="Rollback: versión del registry a la que vuelve @champion")
    p.add_argument("--export-only", action="store_true", help="No registra: solo exporta el @champion actual")
    p.add_argument("--reason", default="",
                   help="Justificación de la decisión (obligatoria al promover o hacer rollback)")
    p.add_argument("--promoted-by", default=os.environ.get("GITHUB_ACTOR") or os.environ.get("USER", "unknown"))
    p.add_argument("--tracking-uri", default=os.environ.get("MLFLOW_TRACKING_URI"))
    a = p.parse_args(argv)

    modes = [bool(a.run_id or a.segment_map), bool(a.version), a.export_only]
    if sum(modes) != 1:
        p.error("usa uno: --run-id + --segment-map (promover) | --version (rollback) | --export-only")
    if bool(a.run_id) != bool(a.segment_map):
        p.error("--run-id y --segment-map van juntos")
    if not a.export_only and not a.reason.strip():
        p.error("--reason es obligatorio al promover o hacer rollback")
    if not a.export_uri:
        p.error("falta --export-uri (o VANTIX_CHAMPION_URI)")

    mlflow.set_tracking_uri(a.tracking_uri)
    client = MlflowClient()
    if a.run_id:
        register(client, a.run_id, a.segment_map, a.promoted_by, a.reason)
    elif a.version:
        rollback(client, a.version, a.promoted_by, a.reason)
    export_champion(client, a.export_uri)


if __name__ == "__main__":
    main()
