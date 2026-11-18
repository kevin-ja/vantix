"""Migra un servidor de MLflow a otro: experimentos, runs, LoggedModels (MLflow 3) y Model Registry.

    MLFLOW_TRACKING_USERNAME=admin MLFLOW_TRACKING_PASSWORD=… \\
    python scripts/migrate_mlflow.py --src <uri origen> --dst <uri destino> --mapping-out mapping.json

Qué copia, por experimento (salvo "Default" vacío):
  - runs: nombre, fechas, estado, params, historial completo de métricas, tags y artefactos.
    Los padres van antes que los hijos (se remapea mlflow.parentRunId).
  - LoggedModels: params, tags, tipo y artefactos (MLmodel, pickle…), ligados al run nuevo.
  - Model Registry: modelos, versiones (mismo número), tags, descripciones y alias (@champion, @benchmark…).

Los IDs cambian (MLflow no permite elegirlos). Trazabilidad: cada run/modelo nuevo lleva el tag
`migrated_from_run_id` / `migrated_from_model_id`, y --mapping-out guarda el mapa viejo → nuevo.
Pensado para un destino vacío: si el experimento ya existe en el destino, falla.
"""
from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

import mlflow
from mlflow.entities import Metric, Param, ViewType
from mlflow.tracking import MlflowClient

PARENT_TAG = "mlflow.parentRunId"
SKIP_MODEL_TAGS = {"mlflow.modelVersions"}  # la recalcula el destino al registrar versiones


def chunks(items: list, n: int):
    for i in range(0, len(items), n):
        yield items[i:i + n]


def all_runs(client: MlflowClient, exp_id: str) -> list:
    runs, token = [], None
    while True:
        page = client.search_runs([exp_id], run_view_type=ViewType.ACTIVE_ONLY, max_results=1000, page_token=token)
        runs += list(page)
        token = page.token
        if not token:
            break
    # Padres primero (sin parentRunId), luego hijos; dentro de cada grupo, por fecha.
    return sorted(runs, key=lambda r: (PARENT_TAG in r.data.tags, r.info.start_time or 0))


def copy_run(src: MlflowClient, dst: MlflowClient, run, dst_exp: str, run_map: dict) -> str:
    tags = dict(run.data.tags)
    if PARENT_TAG in tags:
        tags[PARENT_TAG] = run_map[tags[PARENT_TAG]]
    tags["migrated_from_run_id"] = run.info.run_id
    new = dst.create_run(dst_exp, start_time=run.info.start_time, tags=tags, run_name=run.info.run_name)
    new_id = new.info.run_id

    params = [Param(k, v) for k, v in run.data.params.items()]
    for batch in chunks(params, 100):
        dst.log_batch(new_id, params=batch)
    metrics = [Metric(m.key, m.value, m.timestamp, m.step)
               for key in run.data.metrics for m in src.get_metric_history(run.info.run_id, key)]
    for batch in chunks(metrics, 1000):
        dst.log_batch(new_id, metrics=batch)

    if src.list_artifacts(run.info.run_id):
        with tempfile.TemporaryDirectory() as tmp:
            local = src.download_artifacts(run.info.run_id, "", tmp)
            dst.log_artifacts(new_id, local)

    dst.set_terminated(new_id, status=run.info.status, end_time=run.info.end_time)
    return new_id


def copy_logged_models(src: MlflowClient, dst: MlflowClient, src_exp: str, dst_exp: str,
                       run_map: dict) -> dict:
    model_map = {}
    for m in src.search_logged_models([src_exp]):
        tags = {k: v for k, v in (m.tags or {}).items() if k not in SKIP_MODEL_TAGS}
        tags["migrated_from_model_id"] = m.model_id
        new = dst.create_logged_model(dst_exp, name=m.name, source_run_id=run_map.get(m.source_run_id),
                                      tags=tags, params=m.params or None, model_type=m.model_type)
        with tempfile.TemporaryDirectory() as tmp:
            # Directo desde su ubicación (s3://…, ruta local…): `models:/m-…` se resolvería contra el MLflow
            # global del proceso, no contra el origen.
            local = mlflow.artifacts.download_artifacts(artifact_uri=m.artifact_location, dst_path=tmp)
            dst.log_model_artifacts(new.model_id, local)
        dst.finalize_logged_model(new.model_id, "READY")
        model_map[m.model_id] = new.model_id
    return model_map


def use_global(uri: str) -> None:
    """Algunas operaciones dependen del MLflow global del proceso, no del cliente:
    - el plugin sagemaker-mlflow autentica según el tracking URI global (debe ser el origen al leerlo);
    - con un destino local (sqlite), el registry resuelve `models:/…` contra el global (debe ser el destino).
    Las subidas de artefactos usan el tracking URI de su propio cliente."""
    mlflow.set_tracking_uri(uri)
    mlflow.set_registry_uri(uri)


def copy_registry(src: MlflowClient, dst: MlflowClient, src_uri: str, dst_uri: str, run_map: dict,
                  model_map: dict) -> dict:
    # 1. Leer todo el registry del origen (global = origen) …
    registry = [(rm, sorted(src.search_model_versions(f"name='{rm.name}'"), key=lambda v: int(v.version)))
                for rm in src.search_registered_models()]
    # 2. … y escribir en el destino. Un destino HTTP resuelve las fuentes en el servidor; uno local, con el global.
    if not dst_uri.startswith(("http://", "https://")):
        use_global(dst_uri)
    out = {}
    for rm, versions in registry:
        dst.create_registered_model(rm.name, tags=rm.tags or None, description=rm.description)
        out[rm.name] = {}
        for mv in versions:
            old_model = mv.source.removeprefix("models:/") if mv.source.startswith("models:/m-") else None
            new_run = run_map.get(mv.run_id)
            if old_model:
                source, model_id = f"models:/{model_map[old_model]}", model_map[old_model]
            else:  # versiones de MLflow 2: runs:/<run>/<path>
                source, model_id = mv.source.replace(mv.run_id, new_run), None
            new = dst.create_model_version(rm.name, source, run_id=new_run, tags=mv.tags or None,
                                           description=mv.description, model_id=model_id)
            if new.version != mv.version:
                raise RuntimeError(f"{rm.name}: versión {mv.version} quedó como {new.version} (¿destino no vacío?)")
            out[rm.name][mv.version] = {"run_id": new_run, "model_id": model_id}
        for alias, version in (rm.aliases or {}).items():
            dst.set_registered_model_alias(rm.name, alias, version)
        out[rm.name]["aliases"] = dict(rm.aliases or {})
    return out


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src", required=True, help="Tracking URI de origen")
    p.add_argument("--dst", required=True, help="Tracking URI de destino (vacío)")
    p.add_argument("--mapping-out", required=True, help="JSON con el mapa de IDs viejo → nuevo")
    a = p.parse_args(argv)

    src, dst = MlflowClient(a.src), MlflowClient(a.dst)
    use_global(a.src)
    mapping = {"src": a.src, "dst": a.dst, "experiments": {}, "runs": {}, "logged_models": {}}

    for exp in src.search_experiments():
        runs = all_runs(src, exp.experiment_id)
        if exp.name == "Default" and not runs:
            continue
        if dst.get_experiment_by_name(exp.name):
            raise SystemExit(f"El experimento {exp.name!r} ya existe en el destino (se espera un destino vacío)")
        dst_exp = dst.create_experiment(exp.name, tags={k: v for k, v in (exp.tags or {}).items()
                                                          if not k.startswith("mlflow.")} or None)
        for run in runs:
            mapping["runs"][run.info.run_id] = copy_run(src, dst, run, dst_exp, mapping["runs"])
        mapping["logged_models"].update(copy_logged_models(src, dst, exp.experiment_id, dst_exp,
                                                           mapping["runs"]))
        mapping["experiments"][exp.name] = {"src": exp.experiment_id, "dst": dst_exp, "runs": len(runs)}
        print(f"experimento {exp.name}: {len(runs)} runs")

    mapping["registry"] = copy_registry(src, dst, a.src, a.dst, mapping["runs"], mapping["logged_models"])
    Path(a.mapping_out).write_text(json.dumps(mapping, indent=2))
    print(f"runs: {len(mapping['runs'])} · logged models: {len(mapping['logged_models'])} · "
          f"modelos registrados: {list(mapping['registry'])} → {a.mapping_out}")


if __name__ == "__main__":
    main()
