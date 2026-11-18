# VANTIX · Segmentación de clientes

Arquitectura: [`docs/training_pipeline_arch.md`](docs/training_pipeline_arch.md) · [`docs/inference_pipeline_arch.md`](docs/inference_pipeline_arch.md) · Problema de negocio: [`bussines_problem.md`](bussines_problem.md)

## Estructura

```
pipelines/
  common/        config, io, validate, features, transformers (Winsorizer),
                 storage (local/S3), champion (contrato de models/champion/), orchestration  ← training + inference
  training/
    steps/       prepare.py (Processing job) · train.py (Training job)
    evaluation.py · promote.py · pipeline_sagemaker.py · requirements.txt
  inference/
    steps/       score.py (Processing job)
    pipeline_sagemaker.py · requirements.txt
infra/
  shared/        S3 de datos + MLflow administrado
  training/      rol de ejecución del pipeline
  inference/     bucket de scores + rol de ejecución + EventBridge Scheduler (semanal, apagado por defecto)
scripts/upload_raw.py   CSV -> Parquet -> s3://…/raw/ingest_date=…/
tests/
```

## Local (sin AWS, sin costo)

```bash
make venv          # Python 3.11 + scikit-learn 1.4.2 (misma versión que el contenedor de SageMaker)
make test
make train-local K_MIN=2 K_MAX=10      # MLflow en .local/mlflow.db
.venv/bin/mlflow ui --backend-store-uri sqlite:///.local/mlflow.db

# inferencia local: promover un run hijo y puntuar data/data.csv
make promote-local RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/2025-04-30_k5.json REASON="prueba"   # -> .local/models/champion/
make inference-local                                                 # -> .local/scores/scoring_date=2025-05-01/
```

## AWS: primera corrida (manual)

> `pipeline-*` e `inference-*` solo corren con el código commiteado y pusheado (`make check-clean`): así el `git_commit` registrado existe en GitHub.

Requisitos: perfil `vantix` (`make login`) y cuota de `ml.m5.xlarge` para training jobs aprobada.

```bash
make login                          # aws sso login --profile vantix
make up-training                    # bucket de estado + shared (S3, MLflow ~20 min) + training (IAM)
make upload-raw INGEST_DATE=2025-04-30
make pipeline-run INGEST_DATE=2025-04-30 SNAPSHOT_DATE=2025-04-30 K_MIN=2 K_MAX=10
```

Seguimiento en SageMaker Studio → Pipelines → `vantix-training`. Después, en MLflow:

1. Revisar el experimento `vantix-segmentation`: run padre por corrida, run hijo por k (métricas y `profile/`).
2. Elegir k según los criterios de `docs/training_pipeline_arch.md` §3.8.
3. Comparar contra el benchmark fijo `s3://…/models/benchmark/` (perfil de clusters y métricas por k).
4. Nombrar los grupos en `segment_maps/<snapshot_date>_k<k>.json` (por PR).
5. Promover desde GitHub (Actions → promote, con aprobación) o en local: `make promote RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/… REASON="…"` → `@champion` + exporta a `s3://…/models/champion/`. Rollback: `make rollback VERSION=<n> REASON="…"`. Detalle: [`docs/arch_mlops.md`](docs/arch_mlops.md) §5.

## AWS: inferencia

Requisitos: un `@champion` exportado (`make promote`) y datos en `raw/`. MLflow puede estar apagado.

```bash
make up-inference                   # bucket de scores + rol + scheduler (apagado)
make inference-run INF_SNAPSHOT=2025-04-30 SCORING_DATE=2025-05-01   # datos históricos
make schedule-on                    # tras validar la corrida: cada lunes 06:00 UTC con fechas "auto"
```

Salida: `s3://vantix-<cuenta>-scores/scores/scoring_date=…/scores.parquet` + `summary.json`, y `scores/latest.json` (lo lee la API de campañas). Rollback: reasignar `@champion` en MLflow → `make promote-export`.

## Costos

| Recurso | Precio (us-east-1) | Se cobra |
|---|---|---|
| MLflow Tracking Server Small | USD 0,60/h | mientras está encendido → `make mlflow-stop` al terminar |
| Training `ml.m5.xlarge` | USD 0,23/h | solo mientras corre |
| Processing `ml.t3.xlarge` | USD 0,20/h | solo mientras corre |
| S3 | USD 0,023/GB-mes | por lo guardado |

## Apagar

```bash
make mlflow-stop                    # conserva experimentos y modelos; mlflow-start para volver
make down-training                  # quita el rol de training
make down-inference                 # quita bucket de scores, rol y scheduler
make down-all CONFIRM=yes           # borra todo, incluidos datos y modelos
```
