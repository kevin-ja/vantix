"""Diagrama de arquitectura del pipeline de entrenamiento (ver training_pipeline_arch.md).

    source docs/.venv/bin/activate
    python docs/training_pipeline_diagram.py      # -> docs/img/training_pipeline.png

Requiere Graphviz (`dot`) en el PATH.
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.ml import SagemakerModel, SagemakerTrainingJob, Sagemaker
from diagrams.aws.security import IAMRole
from diagrams.aws.storage import SimpleStorageServiceS3Bucket as Bucket
from diagrams.onprem.client import User
from diagrams.onprem.iac import Terraform
from diagrams.onprem.mlops import Mlflow
from diagrams.programming.language import Python

OUT = Path(__file__).resolve().parent / "img" / "training_pipeline"
OUT.parent.mkdir(exist_ok=True)

GRAPH = {"pad": "0.4", "nodesep": "0.7", "ranksep": "1.0", "fontsize": "22"}

with Diagram("VANTIX · Pipeline de entrenamiento", filename=str(OUT), outformat="png",
             show=False, direction="LR", graph_attr=GRAPH):
    upload = Python("scripts/upload_raw.py\nCSV → Parquet")

    with Cluster("S3 · bucket de datos (versionado)"):
        raw = Bucket("raw/\ningest_date=…/")
        silver = Bucket("silver/user_features/\nsnapshot_date=…/")
        champion_s3 = Bucket("models/champion/\npreprocessor.pkl · model.pkl\nsegment_map.json · manifest.json")

    with Cluster("SageMaker Pipelines · vantix-training"):
        prepare = Sagemaker("Processing job\n1 Ingesta · 2 Validación\n3 Limpieza · 4 Features")
        train = SagemakerTrainingJob("Training job\n5 Preprocesamiento (fit)\n6 KMeans por k\n7 Evaluación (100 %)")
        role = IAMRole("vantix-training-exec")

    with Cluster("MLflow"):
        tracking = Mlflow("Experimento\nvantix-segmentation\nrun padre + hijo por k")
        registry = SagemakerModel("Model Registry\nvantix-segmentation\n@champion")

    reviewer = User("8 Revisión manual\nelige k · nombra grupos")
    tf = Terraform("infra/shared\ninfra/training")

    upload >> raw >> prepare >> silver >> train
    train >> Edge(label="métricas · perfiles · .pkl") >> tracking
    tracking >> Edge(style="dashed") >> reviewer
    reviewer >> Edge(label="make promote") >> registry
    registry >> Edge(label="exporta (mismo run)") >> champion_s3

    role - Edge(style="dotted", label="asume") - prepare
    tf >> Edge(style="dotted", label="crea") >> role
