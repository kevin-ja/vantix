"""Orquestación del pipeline de inferencia en SageMaker (capa delgada, 1 Processing job).

La lógica vive en pipelines/inference/steps/score.py.

    python -m pipelines.inference.pipeline_sagemaker upsert
    python -m pipelines.inference.pipeline_sagemaker run [--snapshot-date 2025-04-30 --scoring-date 2025-05-01]

Config por variables de entorno (las pone el Makefile desde los outputs de Terraform):
    VANTIX_BUCKET, VANTIX_SCORES_BUCKET, VANTIX_ROLE_ARN, VANTIX_REGION, AWS_PROFILE

Los parámetros de fecha valen "auto" por defecto (así los lanza EventBridge Scheduler cada semana):
ingest_date = última partición de raw/, scoring_date = hoy (UTC), snapshot_date = scoring_date - 1.
"""
from __future__ import annotations

import argparse
import os

import boto3
from sagemaker.processing import FrameworkProcessor
from sagemaker.sklearn.estimator import SKLearn
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

PIPELINE_NAME = "vantix-inference"  # infra/inference/ (scheduler e IAM) usa este mismo nombre


def build_pipeline(session: PipelineSession, bucket: str, scores_bucket: str, role: str, region: str) -> Pipeline:
    ingest_date = ParameterString("IngestDate", default_value="auto")
    snapshot_date = ParameterString("SnapshotDate", default_value="auto")
    scoring_date = ParameterString("ScoringDate", default_value="auto")
    window_days = ParameterInteger("WindowDays", default_value=30)
    reference_rows = ParameterInteger("ReferenceRows", default_value=0)
    commit = ParameterString("GitCommit", default_value=git_commit())  # se fija en el upsert

    source_dir = stage_source(
        REPO / "pipelines" / "inference" / "requirements.txt",
        {"score_entry.py": "pipelines.inference.steps.score"},
    )

    processor = FrameworkProcessor(
        estimator_cls=SKLearn,
        framework_version=SKLEARN_VERSION,
        role=role,
        instance_type=PROCESSING_INSTANCE,
        instance_count=1,
        base_job_name="vantix-score",
        sagemaker_session=session,
        code_location=f"s3://{bucket}/pipelines",
        env={"AWS_DEFAULT_REGION": region, "GIT_COMMIT": commit},
    )
    # Sin ProcessingInput/Output: score.py lee y escribe S3 él mismo para escribir latest.json al final.
    score_args = processor.run(
        code="score_entry.py",
        source_dir=source_dir,
        arguments=[
            "--raw-uri", f"s3://{bucket}/raw",
            "--champion-uri", f"s3://{bucket}/models/champion",
            "--output-uri", f"s3://{scores_bucket}/scores",
            "--ingest-date", ingest_date,
            "--snapshot-date", snapshot_date,
            "--scoring-date", scoring_date,
            "--window-days", window_days.to_string(),
            "--reference-rows", reference_rows.to_string(),
        ],
    )

    return Pipeline(
        name=PIPELINE_NAME,
        parameters=[ingest_date, snapshot_date, scoring_date, window_days, reference_rows, commit],
        steps=[ProcessingStep(name="Score", step_args=score_args)],
        sagemaker_session=session,
    )


def main(argv=None) -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("upsert", help="Crea o actualiza el pipeline (sube el código actual)")
    run = sub.add_parser("run", help="Upsert + ejecución")
    run.add_argument("--ingest-date", default="auto")
    run.add_argument("--snapshot-date", default="auto")
    run.add_argument("--scoring-date", default="auto")
    run.add_argument("--window-days", type=int, default=30)
    run.add_argument("--reference-rows", type=int, default=0)
    a = p.parse_args(argv)

    bucket, scores_bucket, role = env("VANTIX_BUCKET"), env("VANTIX_SCORES_BUCKET"), env("VANTIX_ROLE_ARN")
    region = os.environ.get("VANTIX_REGION", "us-east-1")
    boto_session = boto3.Session(profile_name=os.environ.get("AWS_PROFILE"), region_name=region)
    session = PipelineSession(boto_session=boto_session, default_bucket=bucket, default_bucket_prefix="pipelines")

    pipeline = build_pipeline(session, bucket, scores_bucket, role, region)
    pipeline.upsert(role_arn=role)
    print(f"Pipeline {PIPELINE_NAME} actualizado")

    if a.cmd == "run":
        execution = pipeline.start(parameters={
            "IngestDate": a.ingest_date,
            "SnapshotDate": a.snapshot_date,
            "ScoringDate": a.scoring_date,
            "WindowDays": a.window_days,
            "ReferenceRows": a.reference_rows,
        })
        print(f"Ejecución iniciada: {execution.arn}")


if __name__ == "__main__":
    main()
