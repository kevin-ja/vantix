# VANTIX · Segmentación de clientes

Arquitectura: [`docs/training_pipeline_arch.md`](docs/training_pipeline_arch.md) · [`docs/inference_pipeline_arch.md`](docs/inference_pipeline_arch.md) · Problema de negocio: [`bussines_problem.md`](bussines_problem.md)
· MLflow propio: [`mlflow_server/README.md`](mlflow_server/README.md) · Monitorización: [`monitorization/doc/monitorization_arch.md`](monitorization/doc/monitorization_arch.md)

## Estructura

```
pipelines/
  common/        config, io, validate, features, transformers (Winsorizer),
                 storage (local/S3), champion (contrato de models/champion/), orchestration  ← training + inference
  training/
    steps/       prepare.py (Processing job) · train.py (Processing job mientras la cuota de training jobs sea 0)
    evaluation.py · promote.py · pipeline_sagemaker.py · requirements.txt
  inference/
    steps/       score.py (Processing job)
    pipeline_sagemaker.py · requirements.txt
infra/
  shared/        S3 de datos + roles OIDC de GitHub + conexión al MLflow propio (URL y contraseña en SSM)
  training/      rol de ejecución del pipeline
  inference/     bucket de scores + rol de ejecución + EventBridge Scheduler (semanal, apagado por defecto)
mlflow_server/   servidor de MLflow propio (EC2 + Docker + Litestream → S3 + CloudFront); autocontenido, ver su README
monitorization/  monitoreo de datos (Data Quality + Data Drift → PostgreSQL → Grafana); infra y CI/CD propios
scripts/         upload_raw.py (CSV -> Parquet -> s3://…/raw/ingest_date=…/) · freeze_benchmark.py ·
                 make_synthetic_batch.py · migrate_mlflow.py
segment_maps/    nombres de los segmentos por champion (<snapshot_date>_k<k>.json)
tests/
```

## Local (sin AWS, sin costo)

```bash
make venv          # Python 3.11 + scikit-learn 1.4.2 (misma versión que el contenedor de SageMaker)
make test
make lint          # ruff + terraform fmt (lo mismo corre en CI)
make train-local K_MIN=2 K_MAX=10      # MLflow en .local/mlflow.db
.venv/bin/mlflow ui --backend-store-uri sqlite:///.local/mlflow.db

# inferencia local: promover un run hijo y puntuar data/data.csv
make promote-local RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/2025-04-30_k5.json REASON="prueba"   # -> .local/models/champion/
make inference-local                                                 # -> .local/scores/scoring_date=2025-05-01/
```

## AWS: primera corrida (manual)

> `pipeline-*` e `inference-*` solo corren con el código commiteado y pusheado (`make check-clean`): así el `git_commit` registrado existe en GitHub.

Requisitos: perfil `vantix` (`make login`) y el servidor de MLflow levantado (`mlflow_server/`, `make up`). La cuota de
training jobs (`ml.m5.xlarge`) no hace falta: mientras sea 0, Train corre como Processing job (`ml.t3.xlarge`).

```bash
make login                          # aws sso login --profile vantix
make up-training                    # bucket de estado + shared (S3, OIDC, MLflow) + training (IAM)
make mlflow-start                   # enciende la EC2 de MLflow (~30 s); mlflow-status para ver el estado
make upload-raw INGEST_DATE=2025-04-30
make pipeline-run INGEST_DATE=2025-04-30 SNAPSHOT_DATE=2025-04-30 K_MIN=2 K_MAX=10
```

Seguimiento en SageMaker Studio → Pipelines → `vantix-training`. Después, en MLflow:

1. Revisar el experimento `vantix-segmentation`: run padre por corrida, run hijo por k (métricas y `profile/`).
2. Elegir k según los criterios de `docs/training_pipeline_arch.md` §3.8.
3. Comparar contra el benchmark fijo `s3://…/models/benchmark/` (perfil de clusters y métricas por k).
4. Nombrar los grupos en `segment_maps/<snapshot_date>_k<k>.json` (por PR).
5. Promover desde GitHub (Actions → `promote_best_model_manual`, con aprobación) o en local: `make promote RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/… REASON="…"` → `@champion` + exporta a `s3://…/models/champion/`. Rollback: `rollback_model_manual` o `make rollback VERSION=<n> REASON="…"`.

## AWS: inferencia

Requisitos: un `@champion` exportado (`make promote`) y datos en `raw/`. MLflow puede estar apagado.

```bash
make up-inference                   # bucket de scores + rol + scheduler (apagado)
make inference-run INF_SNAPSHOT=2025-04-30 SCORING_DATE=2025-05-01   # datos históricos
make schedule-on                    # tras validar la corrida: cada lunes 06:00 UTC con fechas "auto"
```

Desde GitHub: Actions → `batch_inference_manual` (con aprobación). Salida: `s3://vantix-<cuenta>-scores/scores/scoring_date=…/scores.parquet` + `summary.json`, y `scores/latest.json` (lo lee la API de campañas).

## CI/CD (GitHub Actions)

| Workflow | Disparo |
|---|---|
| `code_quality_check` | Automático: cada PR y push a `main` (lint, tests, Terraform) |
| `deploy_inference` | Automático: merge con cambios en `pipelines/inference/`; manual con `ref` para rollback |
| `train_pipeline_manual` | Manual: reentrenamiento (features + KMeans → MLflow) |
| `promote_best_model_manual` · `rollback_model_manual` | Manual: cambiar `@champion` |
| `batch_inference_manual` | Manual: puntuar con el `@champion` vigente |
| `ci_monitoring` | Automático: tests + `terraform validate` de `monitorization/`; al mergear, imagen del backend a ECR |
| `run_monitoring_manual` | Manual: corre el monitoreo de datos en la EC2 de monitorización (por SSM) |

## Costos

| Recurso | Precio (us-east-1) | Se cobra |
|---|---|---|
| EC2 `t3.small` de MLflow (y la de monitorización) | USD 0,0208/h | mientras está encendida → `make mlflow-stop` al terminar |
| Elastic IP + disco EBS de cada EC2 | ~USD 5/mes por servidor | siempre, aunque la EC2 esté apagada |
| Processing `ml.t3.xlarge` (Prepare, Train y Score) | USD 0,20/h | solo mientras corre |
| S3 | USD 0,023/GB-mes | por lo guardado |

## Apagar

```bash
make mlflow-stop                    # apaga la EC2 de MLflow; el estado vive en S3 (mlflow-start para volver)
make down-training                  # quita el rol de training
make down-inference                 # quita bucket de scores, rol y scheduler
make down-all CONFIRM=yes           # borra todo, incluidos datos y modelos
```
