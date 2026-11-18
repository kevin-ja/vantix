"""Diagrama de arquitectura del pipeline de inferencia (ver inference_pipeline_arch.md).

    source docs/.venv/bin/activate
    python docs/inference_pipeline_diagram.py     # -> docs/img/inference_pipeline.png

Requiere Graphviz (`dot`) en el PATH.
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import CloudwatchLogs
from diagrams.aws.ml import Sagemaker, SagemakerModel
from diagrams.aws.security import IAMRole
from diagrams.aws.storage import SimpleStorageServiceS3Bucket as Bucket
from diagrams.onprem.client import User
from diagrams.onprem.compute import Server
from diagrams.onprem.iac import Terraform

OUT = Path(__file__).resolve().parent / "img" / "inference_pipeline"
OUT.parent.mkdir(exist_ok=True)

GRAPH = {"pad": "0.4", "nodesep": "0.7", "ranksep": "1.0", "fontsize": "22"}

with Diagram("VANTIX · Pipeline de inferencia (batch semanal)", filename=str(OUT), outformat="png",
             show=False, direction="LR", graph_attr=GRAPH):
    operator = User("make inference-run\n(manual)")
    scheduler = Eventbridge("EventBridge Scheduler\nlunes 06:00 UTC\nfechas = auto")

    with Cluster("S3 · bucket de datos"):
        raw = Bucket("raw/\ningest_date=…/")
        champion = Bucket("models/champion/\npreprocessor.pkl · model.pkl\nsegment_map.json · manifest.json")

    with Cluster("SageMaker Pipelines · vantix-inference"):
        score = Sagemaker("Processing job · sklearn 1.4-2\n1-4 ingesta · validación\nlimpieza · features\n"
                          "5 carga champion\n6 transform · 7 predict\n8 valida y escribe")
        role = IAMRole("vantix-inference-exec")

    with Cluster("S3 · bucket de scores"):
        scores = Bucket("scores/scoring_date=…/\nscores.parquet · summary.json")
        latest = Bucket("scores/latest.json")

    logs = CloudwatchLogs("CloudWatch Logs")
    api = Server("API de campañas\n(solo lectura)")
    registry = SagemakerModel("MLflow Model Registry\n@champion")
    tf = Terraform("infra/inference")

    scheduler >> Edge(label="StartPipelineExecution") >> score
    operator >> Edge(style="dashed") >> score
    raw >> score
    champion >> score
    score >> Edge(label="1º") >> scores
    score >> Edge(label="2º (al final)") >> latest
    score >> Edge(style="dotted") >> logs
    latest >> Edge(label="lee") >> api
    scores >> Edge(label="lee") >> api

    registry >> Edge(style="dashed", label="make promote\n(exporta; MLflow puede estar apagado)") >> champion
    role - Edge(style="dotted", label="asume") - score
    tf >> Edge(style="dotted", label="crea") >> [role, scheduler]
