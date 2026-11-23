# Entrenamiento · levantar desde cero

Pipeline `vantix-training` en SageMaker: **Prepare** (features RFM por usuario) → **Train** (preprocesador + KMeans
por cada k + métricas → MLflow). Después, una persona elige k y **promueve** el run como `@champion`.

Antes: [README de la raíz](../../README.md) §1–§2 (herramientas, perfil de AWS, `make venv`).
Todos los comandos se corren **desde la raíz del repo**. Perfil por defecto `vantix` (`AWS_PROFILE=…` para otro).

## 0. Configuración inicial (parte manual)

- Son 4 pasos. 

- En los ejemplos, tu usuario de GitHub es `ana` y tu repo se llama `vantix`: reemplázalos por los tuyos.

### Paso 1 · Tener tu propia copia del repo en tu GitHub

**Por qué:** los comandos que lanzan cosas en AWS se niegan a correr si tu código no está subido a GitHub (así cada
modelo entrenado registra el commit del codigo que lo esta corriendo, esto es una buena practica en MLops: trazabilidad)

1. Entra al repo original en GitHub (https://github.com/kevin-ja/vantix) y pulsa el botón **Fork** (arriba a la derecha). Se crea
   `github.com/ana/vantix`.
2. En tu fork, abre la pestaña **Actions** y pulsa **"I understand my workflows, go ahead and enable them"**
   (esto es necesario porque GitHub apaga los workflows en los forks).
3. Descarga tu fork a tu máquina y entra a la carpeta:
   ```bash
   git clone https://github.com/ana/vantix.git
   cd vantix
   ```
   🚨 Desde ahora, **todos los comandos se corren dentro de esta directorio local tuyo**.

### Paso 2 · Autorizar tu repo para que GitHub Actions pueda entrar a AWS

**Por qué:** En este sistema, los workflows de Github Actions entran a AWS sin contraseñas (en lugar usa un protocolo OIDC, mucho más seguro y eficiente): AWS solo deja pasar al repo que Terraform tenga
anotado. Por defecto viene anotado el repo original, así que hay que poner el tuyo **antes del primer `make up-*`**.

1. Inicia sesión en GitHub desde la terminal:
   ```bash
   gh auth login
   ```
   Responde: `GitHub.com` → `HTTPS` → `Login with a web browser`, y sigue las instrucciones del navegador hasta que te salga un aviso de login exitoso.
2. Pregúntale a GitHub cómo se identifica tu repo ante AWS:
   ```bash
   gh api repos/ana/vantix/actions/oidc/customization/sub --jq '.sub_claim_prefix | sub("^repo:";"")'
   ```
   Verás que responde una sola línea, de una de estas dos formas (las dos son válidas), por ejemplo:
   ```bash
   # pueder ser:
   ana@81234567/vantix@998877665
   # o:
   ana/vantix
   ```
   Copia **exactamente** lo que te salió.
3. Guárdalo en los dos archivos de configuración que lee Terraform (reemplaza el valor por el tuyo):
   ```bash
   echo 'github_repo = "ana@81234567/vantix@998877665"' >> infra/shared/terraform.tfvars
   echo 'github_repo = "ana@81234567/vantix@998877665"' >> monitorization/infra/terraform.tfvars
   ```
   ⚠️ Si los archivos no existen, tranquilo(a) el comando los crea. Lo normal que no se hayan subido a git (están en `.gitignore`).
4. Comprueba que quedó bien:
   ```bash
   cat infra/shared/terraform.tfvars
   ```
   Debe mostrar algo como: `github_repo = "ana@81234567/vantix@998877665"`.

> 👀 ¿Que pasa si ya habías levantado la infraestructura con terraform? No pasa nada, Corrige el valor en los dos archivos y vuelve a correr
> `make up-training` y `cd monitorization && make up`. Hasta entonces AWS sigue usando el valor anterior.

### Paso 3 · Descargar el dataset

**Por qué:** el dataset no está en git. Está publicado como adjunto del GitHub Release
[`data-v1`](https://github.com/kevin-ja/vantix/releases/tag/data-v1) del repo original (Parquet, ~20 MB, 842.163
apuestas, 19 columnas; significado de cada una en `data/diccionario.txt`). Requiere haber corrido `make venv`.

1. Descárgalo:
   ```bash
   make get-data
   ```
   Crea la carpeta `data/`, descarga `data/data.parquet` con una barra de progreso y lo verifica solo
   (`make check-data`): que el archivo llegó completo (SHA-256) y que pasa las mismas reglas que el pipeline.
2. Si todo salió bien, termina así:
   ```
   ✔ DATA OK: 842,163 rows · 108,315 users · 2025-03-11 → 2025-04-30
   Next step: make upload-data INGEST_DATE=2025-04-30
   ```
   Si algo falla, muestra `✘ DOWNLOAD FAILED` o `✘ DATA CHECK FAILED` con el error exacto. Vuelve a correr
   `make get-data` (sobrescribe la descarga anterior).

### Paso 4 · Configurar GitHub (solo si vas a entrenar desde GitHub Actions)

Se hace después de levantar la infraestructura, porque los valores salen de ella: ver §5.

> No necesitas pedir a AWS la cuota de training jobs: mientras sea 0, el paso Train corre como Processing job
> (`ml.t3.xlarge`), que ya viene habilitado.

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
make upload-data INGEST_DATE=2025-04-30   # verifica data/data.parquet y lo sube a s3://vantix-<cuenta>-data/raw/ingest_date=2025-04-30/
```

Antes de subir corre `make check-data`: si el archivo no pasa, no sube nada. `INGEST_DATE` es la etiqueta del lote
y debe ser la misma que luego se pasa a `make pipeline-run`. La ruta es inmutable: si ya existe, falla (usar otra
`INGEST_DATE`).

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
