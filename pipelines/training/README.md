# Entrenamiento · levantar desde cero

Pipeline `vantix-training` en SageMaker: **Prepare** (features RFM por usuario) → **Train** (preprocesador + KMeans
por cada k + métricas → MLflow). Después, una persona elige k y **promueve** el run como `@champion`.

Antes: [README de la raíz](../../README.md) §1–§2 (herramientas, perfil de AWS, `make venv`).
Todos los comandos se corren **desde la raíz del repo**. Perfil por defecto `vantix` (`AWS_PROFILE=…` para otro).

## 0. Lo que se hace a mano (una vez)

1. **Tu propio repo en GitHub** (fork o copia) y el código pusheado: los comandos de AWS solo corren con el commit
   presente en GitHub (`make check-clean`), para que el `git_commit` registrado exista.
2. **Repo autorizado para OIDC.** Terraform trae por defecto el repo original; sin cambiarlo, los workflows no
   entran a AWS. Antes de cualquier `make up-*`:
   ```bash
   export TF_VAR_github_repo=$(gh api repos/<owner>/<repo> --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"')
   ```
3. **Dataset** en `data/data.csv` (19 columnas, ver `pipelines/common/config.py` → `RAW_COLUMNS` y `diccionario.txt`).
4. **GitHub** (solo para correr desde Actions; ver §5).

No hace falta la cuota de training jobs: mientras sea 0, Train corre como Processing job (`ml.t3.xlarge`).

## 1. Infraestructura (Terraform)

```bash
make bootstrap            # bucket del estado de Terraform: vantix-<cuenta>-tfstate (idempotente)
make mlflow-server-up     # servidor de MLflow (EC2 + CloudFront); ver mlflow_server/README.md
make up-training          # infra/shared (S3 de datos, OIDC, roles de GitHub) + infra/training (rol de ejecución)
```

Qué crea (todo con Terraform; nada de IAM a mano):

| Recurso | Archivo | Permisos |
|---|---|---|
| Bucket de datos `vantix-<cuenta>-data` (versionado, cifrado, privado) | `infra/shared/main.tf` | — |
| Rol `vantix-training-exec` (lo usan los jobs) | `infra/training/main.tf` | S3 del bucket de datos, jobs de SageMaker, imágenes sklearn de ECR, logs, contraseña de MLflow en SSM |
| Proveedor OIDC de GitHub + rol `vantix-github-train` | `infra/shared/github.tf` | crear/actualizar/ejecutar `vantix-training`, pasar el rol de ejecución, encender/apagar la EC2 de MLflow |
| Rol `vantix-github-promote` | `infra/shared/github.tf` | contraseña de MLflow, leer `models/`, escribir `models/champion/` |

Los roles de GitHub solo los asumen workflows del repo autorizado que corren en el environment `production`.

## 2. Datos a S3

```bash
make upload-raw INGEST_DATE=2025-04-30    # data/data.csv -> Parquet -> s3://…/raw/ingest_date=2025-04-30/data.parquet
```

La ruta es inmutable: si ya existe, falla (usar otra `INGEST_DATE`).

## 3. Entrenar

```bash
make mlflow-start         # enciende la EC2 de MLflow (~30 s)
make pipeline-run INGEST_DATE=2025-04-30 SNAPSHOT_DATE=2025-04-30 K_MIN=2 K_MAX=10
```

| Variable | Qué es | Por defecto |
|---|---|---|
| `INGEST_DATE` | partición de `raw/` que se lee | `2025-04-30` |
| `SNAPSHOT_DATE` | día de corte de las features | `2025-04-30` |
| `WINDOW_DAYS` | días hacia atrás desde el corte | `30` |
| `K_MIN`, `K_MAX` | rango de k que se prueba | `2`, `10` |

Se pasan en el comando; los valores por defecto viven en `Makefile` (y en el formulario de
`.github/workflows/train_pipeline_manual.yml`). Seguimiento: SageMaker Studio → Pipelines → `vantix-training`
(~25 min con k=2..10).

## 4. Elegir k y promover

1. MLflow (`make mlflow-status` muestra la URL; usuario `admin`, contraseña: `make mlflow-server-password`):
   experimento `vantix-segmentation`, un run padre por corrida y un run hijo por k (métricas y `profile/`).
2. Nombrar los grupos en `segment_maps/<snapshot_date>_k<k>.json` (ejemplo: `segment_maps/2025-04-30_k5.json`) y subirlo por PR.
3. Promover:
   ```bash
   make promote RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/2025-04-30_k5.json REASON="primer champion"
   ```
   → alias `@champion` en el registry + exporta a `s3://…/models/champion/` (lo que lee la inferencia).
4. Solo la primera vez: `make benchmark-freeze` (copia el champion v1 a `models/benchmark/`, referencia fija).
5. `make mlflow-stop`.

Rollback: `make rollback VERSION=<n> REASON="…"`.

## 5. Desde GitHub Actions (opcional)

En el repo: **Settings → Environments → `production`** (con aprobador) y estas **variables** (Settings → Variables):

| Variable | Valor |
|---|---|
| `DATA_BUCKET` | `terraform -chdir=infra/shared output -raw data_bucket` |
| `MLFLOW_TRACKING_URI` | `terraform -chdir=infra/shared output -raw mlflow_tracking_uri` |
| `MLFLOW_PASSWORD_PARAM` | `terraform -chdir=infra/shared output -raw mlflow_password_param` |
| `GH_TRAIN_ROLE_ARN` | `terraform -chdir=infra/shared output -raw github_train_role_arn` |
| `GH_PROMOTE_ROLE_ARN` | `terraform -chdir=infra/shared output -raw github_promote_role_arn` |
| `TRAINING_EXEC_ROLE_ARN` | `terraform -chdir=infra/training output -raw training_role_arn` |

Ejemplo: `gh variable set DATA_BUCKET -b "$(terraform -chdir=infra/shared output -raw data_bucket)"`.

Luego: Actions → `train_pipeline_manual` (enciende y apaga MLflow solo) → `promote_best_model_manual` /
`rollback_model_manual`.
