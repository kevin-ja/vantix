"""Orquestación del pipeline de entrenamiento en SageMaker (capa delgada).

Solo conecta los scripts de pipelines/training/steps/ con jobs de SageMaker. La lógica de ML no vive aquí:
para cambiar de orquestador basta con reescribir este archivo.

    python -m pipelines.training.pipeline_sagemaker upsert
    python -m pipelines.training.pipeline_sagemaker run --ingest-date 2025-04-30 --snapshot-date 2025-04-30

Config por variables de entorno (las pone el Makefile desde los outputs de Terraform):
    VANTIX_BUCKET, VANTIX_ROLE_ARN, VANTIX_MLFLOW_URI, VANTIX_MLFLOW_PASSWORD_PARAM, VANTIX_REGION, AWS_PROFILE
"""
from __future__ import annotations

import argparse
import os

import boto3
from sagemaker.processing import FrameworkProcessor, ProcessingInput, ProcessingOutput
from sagemaker.sklearn.estimator import SKLearn
from sagemaker.workflow.execution_variables import ExecutionVariables
from sagemaker.workflow.functions import Join
from sagemaker.workflow.parameters import ParameterInteger, ParameterString
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.pipeline_context import PipelineSession
from sagemaker.workflow.steps import ProcessingStep

from pipelines.common.orchestration import (
    PROCESSING_INSTANCE,
    REPO,
    SKLEARN_VERSION,
    env,
    git_commit,
    stage_source,
)

PIPELINE_NAME = "vantix-training"
TRAINING_INSTANCE = "ml.m5.xlarge"     # cuota solicitada: 1 (en revisión; hoy Train usa PROCESSING_INSTANCE)


def build_pipeline(session: PipelineSession, bucket: str, role: str, mlflow_uri: str, mlflow_password_param: str,
                   region: str) -> Pipeline:
    ingest_date = ParameterString("IngestDate", default_value="2025-04-30")
    snapshot_date = ParameterString("SnapshotDate", default_value="2025-04-30")
    window_days = ParameterInteger("WindowDays", default_value=30)
    reference_rows = ParameterInteger("ReferenceRows", default_value=0)
    k_min = ParameterInteger("KMin", default_value=2)
    k_max = ParameterInteger("KMax", default_value=10)
    # El código se sube en el upsert: el commit se fija ahí.
    commit = ParameterString("GitCommit", default_value=git_commit())

    source_dir = stage_source(
        REPO / "pipelines" / "training" / "requirements.txt",
        {"prepare_entry.py": "pipelines.training.steps.prepare", "train_entry.py": "pipelines.training.steps.train"},
    )
    raw_uri = Join(on="", values=[f"s3://{bucket}/raw/ingest_date=", ingest_date, "/"])
    silver = Join(on="", values=[f"s3://{bucket}/silver/user_features/snapshot_date=", snapshot_date])
    # Une Prepare y Train en MLflow: Prepare crea el run padre con este tag y Train lo busca (sin pasar archivos).
    execution_id = ExecutionVariables.PIPELINE_EXECUTION_ID
    # Servidor propio (mlflow_server/): la contraseña se lee de SSM en el job con el rol de ejecución.
    mlflow_env = {
        "MLFLOW_TRACKING_URI": mlflow_uri,
        "MLFLOW_TRACKING_USERNAME": "admin",
        "MLFLOW_TRACKING_PASSWORD_PARAM": mlflow_password_param,
        "AWS_DEFAULT_REGION": region,
    }

    # 1-4. Processing job: ingesta -> validación -> limpieza -> features (+ metadata de los datos en MLflow)
    processor = FrameworkProcessor(
        estimator_cls=SKLearn,
        framework_version=SKLEARN_VERSION,
        role=role,
        instance_type=PROCESSING_INSTANCE,
        instance_count=1,
        base_job_name="vantix-prepare",
        sagemaker_session=session,
        code_location=f"s3://{bucket}/pipelines/code",
        env=mlflow_env,
    )
    prepare_args = processor.run(
        code="prepare_entry.py",
        source_dir=source_dir,
        inputs=[ProcessingInput(source=raw_uri, destination="/opt/ml/processing/input/raw")],
        outputs=[
            ProcessingOutput(output_name="features", source="/opt/ml/processing/output/features", destination=silver),
        ],
        arguments=[
            "--input", "/opt/ml/processing/input/raw",
            "--output-dir", "/opt/ml/processing/output",
            "--snapshot-date", snapshot_date,
            "--window-days", window_days.to_string(),
            "--reference-rows", reference_rows.to_string(),
            "--raw-uri", raw_uri,
            "--features-uri", silver,
            "--execution-id", execution_id,
        ],
    )
    step_prepare = ProcessingStep(name="Prepare", step_args=prepare_args)

    # 5-7. Preprocesamiento (fit) -> KMeans por k -> evaluación -> MLflow.
    # Corre como Processing job (ml.t3.xlarge) mientras la cuota de training jobs sea 0; mismo train.py.
    # Para volver a Training job: SKLearn estimator + TrainingStep con TRAINING_INSTANCE (ver historial de git).
    trainer = FrameworkProcessor(
        estimator_cls=SKLearn,
        framework_version=SKLEARN_VERSION,
        role=role,
        instance_type=PROCESSING_INSTANCE,
        instance_count=1,
        base_job_name="vantix-train",
        sagemaker_session=session,
        code_location=f"s3://{bucket}/pipelines/code",
        env=mlflow_env,
    )
    outputs = step_prepare.properties.ProcessingOutputConfig.Outputs
    train_out = Join(on="", values=[f"s3://{bucket}/pipelines/training-output/snapshot_date=", snapshot_date])
    train_args = trainer.run(
        code="train_entry.py",
        source_dir=source_dir,
        inputs=[
            ProcessingInput(source=outputs["features"].S3Output.S3Uri, destination="/opt/ml/processing/input/features"),
        ],
        outputs=[ProcessingOutput(output_name="summary", source="/opt/ml/processing/output/model",
                                  destination=train_out)],
        arguments=[
            "--features-dir", "/opt/ml/processing/input/features",
            "--execution-id", execution_id,
            "--model-dir", "/opt/ml/processing/output/model",
            "--k-min", k_min.to_string(),
            "--k-max", k_max.to_string(),
            "--git-commit", commit,
        ],
    )
    step_train = ProcessingStep(name="Train", step_args=train_args)

    return Pipeline(
        name=PIPELINE_NAME,
        parameters=[ingest_date, snapshot_date, window_days, reference_rows, k_min, k_max, commit],
        steps=[step_prepare, step_train],
        sagemaker_session=session,
    )


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("upsert", help="Crea o actualiza el pipeline (sube el código actual)")
    run = sub.add_parser("run", help="Upsert + ejecución")
    run.add_argument("--ingest-date", required=True)
    run.add_argument("--snapshot-date", required=True)
    run.add_argument("--window-days", type=int, default=30)
    run.add_argument("--reference-rows", type=int, default=0)
    run.add_argument("--k-min", type=int, default=2)
    run.add_argument("--k-max", type=int, default=10)
    a = p.parse_args(argv)

    bucket, role = env("VANTIX_BUCKET"), env("VANTIX_ROLE_ARN")
    mlflow_uri, mlflow_password_param = env("VANTIX_MLFLOW_URI"), env("VANTIX_MLFLOW_PASSWORD_PARAM")
    region = os.environ.get("VANTIX_REGION", "us-east-1")
    boto_session = boto3.Session(profile_name=os.environ.get("AWS_PROFILE"), region_name=region)
    session = PipelineSession(boto_session=boto_session, default_bucket=bucket, default_bucket_prefix="pipelines")

    pipeline = build_pipeline(session, bucket, role, mlflow_uri, mlflow_password_param, region)
    pipeline.upsert(role_arn=role)
    print(f"Pipeline {PIPELINE_NAME} actualizado")

    if a.cmd == "run":
        execution = pipeline.start(parameters={
            "IngestDate": a.ingest_date,
            "SnapshotDate": a.snapshot_date,
            "WindowDays": a.window_days,
            "ReferenceRows": a.reference_rows,
            "KMin": a.k_min,
            "KMax": a.k_max,
        })
        print(f"Ejecución iniciada: {execution.arn}")


if __name__ == "__main__":
    main()
