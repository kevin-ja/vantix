# VANTIX · Segmentación de clientes

Segmenta a los clientes de una casa de apuestas (RFM + `Profit_30d` + `Avg_Odds`, KMeans) en AWS SageMaker, con MLflow
propio, CI/CD en GitHub Actions y monitoreo de datos en Grafana.

Problema de negocio: [`bussines_problem.md`](bussines_problem.md) · Arquitectura: [`docs/training_pipeline_arch.md`](docs/training_pipeline_arch.md)
· [`docs/inference_pipeline_arch.md`](docs/inference_pipeline_arch.md)

## Sistemas

| Sistema | Carpeta | Guía |
|---|---|---|
| Servidor de MLflow | `mlflow_server/` | [`mlflow_server/README.md`](mlflow_server/README.md) |
| Entrenamiento | `pipelines/training/` + `infra/shared`, `infra/training` | [`pipelines/training/README.md`](pipelines/training/README.md) |
| Inferencia (batch semanal) | `pipelines/inference/` + `infra/inference` | sección [AWS: inferencia](#aws-inferencia) |
| Monitorización | `monitorization/` | [`monitorization/doc/`](monitorization/doc/monitorization_arch.md) |

## 1. Requisitos (una vez por máquina)

| Herramienta | Versión | Para qué |
|---|---|---|
| AWS CLI | v2 | acceso a la cuenta |
| Terraform | 1.15.8 | infraestructura |
| Docker con `buildx` | — | imágenes de MLflow y del monitoreo |
| `uv` | — | entornos de Python (`make venv`) |
| `session-manager-plugin` | — | administrar las EC2 sin SSH |
| `gh` (GitHub CLI) | — | variables y workflows de GitHub |
| `make`, `git` | — | — |

## 2. Cuenta de AWS

1. Una cuenta de AWS con permisos de administrador. Región: **`us-east-1`** (fija en los workflows).
2. Perfil de la CLI. El nombre por defecto es `vantix`; otro nombre se pasa con `AWS_PROFILE=<perfil>` en cada `make`.
   ```bash
   aws configure sso --profile vantix     # o: aws configure --profile vantix (llaves de IAM)
   make login                             # aws sso login --profile vantix (cuando venza la sesión)
   aws sts get-caller-identity --profile vantix   # comprobar
   ```
3. Entorno de Python local: `make venv` (Python 3.11 + mismas versiones que SageMaker y MLflow).

Sin secretos en el repo: las contraseñas las genera Terraform y viven en SSM; los workflows entran a AWS por OIDC.

## 3. Orden de levantamiento

Cada sistema depende del anterior:

1. **MLflow** → `make bootstrap` (bucket del estado de Terraform) + `make mlflow-server-up`
2. **Entrenamiento** → [`pipelines/training/README.md`](pipelines/training/README.md)
3. **Inferencia** → necesita un `@champion` promovido ([AWS: inferencia](#aws-inferencia))
4. **Monitorización** → necesita el champion y datos en `raw/` ([`monitorization/doc/ci_cd.md`](monitorization/doc/ci_cd.md))

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
scripts/         upload_raw.py (Parquet/CSV -> s3://…/raw/ingest_date=…/) · check_data.py · freeze_benchmark.py ·
                 make_synthetic_batch.py · migrate_mlflow.py
segment_maps/    nombres de los segmentos por champion (<snapshot_date>_k<k>.json)
tests/
```

## AWS: inferencia

Requisitos: un `@champion` exportado (workflow `promote_best_model_manual`) y datos en `raw/`. MLflow puede estar apagado.

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
