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
| Inferencia (batch) | `pipelines/inference/` + `infra/inference` | [`pipelines/inference/README.md`](pipelines/inference/README.md) |
| Monitorización | `monitorization/` | [`monitorization/README.md`](monitorization/README.md) |

## Por dónde empezar

**Sigue la guía de entrenamiento:** [`pipelines/training/README.md`](pipelines/training/README.md). Parte de cero y
explica qué se hace y por qué en cada paso. Deja listo lo que usan los demás sistemas: herramientas, cuenta de AWS,
repo autorizado, MLflow, datos y un modelo promovido.

| Orden | Sistema | Qué necesita | Cómo |
|---|---|---|---|
| 1 | Entrenamiento y MLflow | nada | Pasos 0 al 13 de [`pipelines/training/README.md`](pipelines/training/README.md), con los scripts de [`pipelines/training/setup/`](pipelines/training/setup/) |
| 2 | Inferencia | un `@champion` promovido | Pasos 0 al 6 de [`pipelines/inference/README.md`](pipelines/inference/README.md), con los scripts de [`pipelines/inference/setup/`](pipelines/inference/setup/) |
| 3 | Monitorización | un `@champion` y datos en `raw/` | Pasos 0 al 7 de [`monitorization/README.md`](monitorization/README.md), con los scripts de [`monitorization/setup/`](monitorization/setup/) |

**Entrenamiento con un comando:** `cp .env.example .env`, complétalo y corre `make train-up` (pasos 1 al 11).

**Lo que debes saber antes:**

- **Cuenta de AWS:** una **member account** dedicada a Vantix, a la que se entra con **SSO**. Todo se crea en
  `us-east-1`. No se recomienda la *management account*, el usuario root ni un IAM user con llaves fijas.
- **Tu máquina:** macOS o Linux (en Windows, WSL2). Los scripts que instalan las herramientas e inician sesión en AWS
  son solo para macOS.
- **Entrenar y promover** se hace siempre desde GitHub Actions y con aprobación, para que cada corrida quede registrada.
- **La infraestructura** se crea con Terraform desde tu máquina, no desde GitHub: requiere permisos de administrador.
- **Sin secretos en el repo:** las contraseñas las genera Terraform y viven en AWS (SSM); los workflows entran a AWS por
  OIDC, sin llaves.

## Estructura

```
pipelines/
  common/        config, io, validate, features, transformers (Winsorizer),
                 storage (local/S3), champion (contrato de models/champion/), orchestration  ← training + inference
  training/
    steps/       prepare.py (Processing job) · train.py (Processing job mientras la cuota de cómputo de AWS SageMaker para Training jobs sea 0)
    evaluation.py · promote.py · pipeline_sagemaker.py · requirements.txt
    setup/       paso1.sh … paso11.sh: preparan todo para entrenar, una sola vez (ver su README)
  inference/
    steps/       score.py (Processing job)
    pipeline_sagemaker.py · requirements.txt
    setup/       paso1.sh … paso3.sh y paso6.sh: preparan la inferencia (ver su README)
infra/
  shared/        S3 de datos + roles OIDC de GitHub + conexión al MLflow propio (URL y contraseña en SSM)
  training/      rol de ejecución del pipeline
  inference/     bucket de scores + rol de ejecución + EventBridge Scheduler (semanal, apagado por defecto)
mlflow_server/   servidor de MLflow propio (EC2 + Docker + Litestream → S3 + CloudFront); autocontenido, ver su README
monitorization/  monitoreo de datos (Data Quality + Data Drift → PostgreSQL → Grafana); infra y CI/CD propios
setup/           make train-up / check / down: run.sh, common/ y los pasos de cada sistema
scripts/         upload_raw.py (Parquet/CSV -> s3://…/raw/ingest_date=…/) · check_data.py · freeze_benchmark.py ·
                 make_synthetic_batch.py · migrate_mlflow.py
segment_maps/    nombres de los segmentos por champion (<snapshot_date>_k<k>.json)
tests/
```

## CI/CD (GitHub Actions)

| Workflow | Disparo |
|---|---|
| `code_quality_check` | Automático: cada PR y push a `main` (lint, tests, Terraform) |
| `deploy_inference` | Automático: merge con cambios en `pipelines/inference/` (excepto `setup/` y `.md`); manual con `ref` para rollback |
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
make train-down                     # apaga la EC2 de MLflow; el estado vive en S3 (make train-up para volver)
make schedule-off                   # apaga la corrida semanal de inferencia
make mlflow-server-down             # quita el cómputo de MLflow (EC2, IP, CloudFront); conserva su bucket
cd monitorization && make down      # quita el cómputo del monitoreo; conserva su bucket y sus datos
```
