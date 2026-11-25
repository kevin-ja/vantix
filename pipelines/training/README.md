# Entrenamiento · levantar desde cero

Pipeline `vantix-training` en SageMaker: **Prepare** (features RFM por usuario) → **Train** (preprocesador + KMeans
por cada k + métricas → MLflow). Después, una persona elige k y **promueve** el run como `@champion`.

Antes de empezar, completa estas dos secciones del README de la raíz:
[1. Requisitos](../../README.md#1-requisitos-una-vez-por-máquina) (herramientas) y
[2. Cuenta de AWS](../../README.md#2-cuenta-de-aws) (perfil de AWS y `make venv`).

Todos los comandos se corren **desde la raíz del repo**. Perfil por defecto `vantix` (`AWS_PROFILE=…` para otro).

## 0. Configuración inicial (parte manual)

- Son 4 pasos. 

- En los ejemplos, tu usuario de GitHub es `ana` y tu repo se llama `vantix`: reemplázalos por los tuyos.

### Antes de los pasos · Tus credenciales de AWS

**Qué cuenta y qué acceso usar:** este proyecto está pensado y probado para una **member account de AWS** (una cuenta
secundaria dentro de una AWS Organization, dedicada solo a Vantix) a la que entras con **SSO** (IAM Identity Center).

- **Member account:** mantiene los recursos, los costos y las cuotas de Vantix separados de tus otros proyectos.
- **SSO:** inicias sesión en el navegador y AWS te da credenciales temporales, sin llaves fijas en tu máquina.

No uses la *management account* de la organización ni el usuario root. Un IAM user con llaves fijas no está probado
en este proyecto y no se recomienda.

En tu máquina necesitas tres cosas activas:

1. **Un perfil de AWS** llamado `vantix`, con permisos de administrador y región `us-east-1` (se crea una sola vez):
   ```bash
   aws configure sso --profile vantix
   ```
2. **La sesión iniciada** (vence cada cierto tiempo; se renueva con el mismo comando):
   ```bash
   aws sso login --profile vantix
   ```
3. **Docker encendido:** `make mlflow-server-up` construye y sube una imagen.

Comprueba que AWS responde. Debe mostrar tu número de cuenta:

```bash
aws sts get-caller-identity --profile vantix --query Account --output text
```

**De dónde salen las credenciales:** viven en tu carpeta personal `~/.aws/`, nunca en el repo. El `Makefile` solo pasa
el **nombre** del perfil (`AWS_PROFILE`, por defecto `vantix`) a Terraform, a la AWS CLI y a Python, y cada uno lo busca
en `~/.aws/`. Si tu perfil se llama distinto, agrégalo a cada comando: `make up-training AWS_PROFILE=mi-perfil`.

GitHub Actions no usa estas credenciales: entra a AWS por OIDC, con los roles que crea Terraform.

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
   🚨 Si algo falla, muestra `✘ DOWNLOAD FAILED` o `✘ DATA CHECK FAILED` con el error exacto. Vuelve a correr
   `make get-data` (sobrescribe la descarga anterior).

### Paso 4 · Preparar GitHub y la cuota de cómputo de AWS SageMaker

**Por qué:** el entrenamiento **siempre se lanza desde GitHub Actions**. Los workflows corren dentro de un
*environment* de GitHub llamado `production`: AWS solo deja entrar a los jobs de ese environment, y cada corrida
espera a que una persona la apruebe.

1. Crea el environment. En tu repo de GitHub: **Settings** → **Environments** → **New environment** → escribe
   `production` (exactamente así, en minúsculas) → **Configure environment**.
2. En esa misma pantalla:
   - marca **Required reviewers** y agrégate a ti (`ana`);
   - deja **sin marcar** *Prevent self-review* (si no, no podrás aprobar tus propias corridas);
   - pulsa **Save protection rules**.
3. Comprueba que existe:
   ```bash
   gh api repos/ana/vantix/environments/production --jq .name
   ```
   Debe responder `production`.
4. Comprueba tu **cuota de cómputo de AWS SageMaker**: cuántas máquinas `ml.t3.xlarge` (las que corren el
   entrenamiento) te deja usar AWS a la vez en *Processing jobs*:
   ```bash
   aws service-quotas list-service-quotas --service-code sagemaker --profile vantix --region us-east-1 \
     --query "Quotas[?QuotaName=='ml.t3.xlarge for processing job usage'].[QuotaCode,Value]" --output text
   ```
   Responde un código y un número. El número debe ser **1 o más**. Si es `0`, pide el aumento con ese código y
   espera a que AWS lo apruebe:
   ```bash
   aws service-quotas request-service-quota-increase --service-code sagemaker --quota-code <código> \
     --desired-value 1 --profile vantix --region us-east-1
   ```
   La cuota de cómputo de AWS SageMaker para *Training jobs* no hace falta: hoy el paso Train corre como un job de tipo Processing

Al environment `production` todavía le faltan sus variables. Se cargan más adelante, en la sección
[2. Conectar GitHub con tu AWS](#2-conectar-github-con-tu-aws-obligatorio),
porque sus valores recién existen después de crear la infraestructura ([1. Infraestructura](#1-infraestructura-iac-infrastructure-as-code)).

## 1. Infraestructura (IaC: Infrastructure as Code)

La infraestructura no se crea a mano en la consola de AWS: está escrita como código y su aprovisionamiento se
automatiza con **Terraform**. Estos comandos crean en tu cuenta todo lo necesario (buckets, roles, permisos y
servidores). El primero solo crea, con la AWS CLI, el bucket donde Terraform guarda su estado:

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

## 2. Conectar GitHub con tu AWS (obligatorio)

**Por qué:** los workflows no saben cuál es tu bucket, tus roles ni tu MLflow. Se lo dices con 6 variables del
environment `production`. No son secretos: las contraseñas siguen en AWS (SSM).

1. Con la infraestructura ya levantada ([1. Infraestructura](#1-infraestructura-iac-infrastructure-as-code)), copia y pega todo este bloque. Solo cambia la primera línea:
   ```bash
   REPO=ana/vantix

   gh variable set DATA_BUCKET            -R $REPO --env production -b "$(terraform -chdir=infra/shared output -raw data_bucket)"
   gh variable set MLFLOW_TRACKING_URI    -R $REPO --env production -b "$(terraform -chdir=infra/shared output -raw mlflow_tracking_uri)"
   gh variable set MLFLOW_PASSWORD_PARAM  -R $REPO --env production -b "$(terraform -chdir=infra/shared output -raw mlflow_password_param)"
   gh variable set GH_TRAIN_ROLE_ARN      -R $REPO --env production -b "$(terraform -chdir=infra/shared output -raw github_train_role_arn)"
   gh variable set GH_PROMOTE_ROLE_ARN    -R $REPO --env production -b "$(terraform -chdir=infra/shared output -raw github_promote_role_arn)"
   gh variable set TRAINING_EXEC_ROLE_ARN -R $REPO --env production -b "$(terraform -chdir=infra/training output -raw training_role_arn)"
   ```
2. Comprueba que quedaron las 6, todas con valor:
   ```bash
   gh variable list -R $REPO --env production
   ```
   Debe verse así (con tu número de cuenta):
   ```
   DATA_BUCKET             vantix-123456789012-data
   GH_PROMOTE_ROLE_ARN     arn:aws:iam::123456789012:role/vantix-github-promote
   GH_TRAIN_ROLE_ARN       arn:aws:iam::123456789012:role/vantix-github-train
   MLFLOW_PASSWORD_PARAM   /vantix-mlflow/admin-password
   MLFLOW_TRACKING_URI     https://xxxxxxxxxxxxxx.cloudfront.net
   TRAINING_EXEC_ROLE_ARN  arn:aws:iam::123456789012:role/vantix-training-exec
   ```

🚨 Si destruyes y vuelves a crear el servidor de MLflow, su URL puede cambiar: repite este paso.

## 3. Datos a S3

```bash
make upload-data INGEST_DATE=2025-04-30   # verifica data/data.parquet y lo sube a s3://vantix-<cuenta>-data/raw/ingest_date=2025-04-30/
```

Antes de subir corre `make check-data`: si el archivo no pasa, no sube nada. `INGEST_DATE` es la etiqueta del lote:
anótala, es la misma que pondrás en el formulario de la sección [4. Entrenar](#4-entrenar-desde-github-actions). La ruta es inmutable: si ya existe, falla (usar otra
`INGEST_DATE`).

## 4. Entrenar (desde GitHub Actions)

1. En tu repo: pestaña **Actions** → en la lista de la izquierda **train_pipeline_manual** → botón **Run workflow**.
2. Deja la rama en `main` y llena el formulario:

   | Campo | Qué es | Qué poner la primera vez |
   |---|---|---|
   | `ingest_date` | lote de `raw/` que se lee (el `INGEST_DATE` que usaste en [3. Datos a S3](#3-datos-a-s3)) | `2025-04-30` |
   | `snapshot_date` | día de corte de las features | `2025-04-30` |
   | `window_days` | días hacia atrás desde el corte | `30` |
   | `k_min`, `k_max` | rango de cantidad de grupos que se prueba | `2`, `10` |
   | `keep_mlflow_on` | dejar MLflow encendido al terminar | **marcado** (lo necesitas en [5. Elegir k y promover](#5-elegir-k-y-promover-desde-github-actions)) |

3. Pulsa **Run workflow**. La corrida queda en **Waiting**: ábrela → **Review deployments** → marca `production` →
   **Approve and deploy**. Sin este paso no arranca.
4. Espera (~35 min con k de 2 a 10). El workflow hace todo solo: enciende MLflow, crea o actualiza el pipeline
   `vantix-training` en SageMaker, lo ejecuta y espera el resultado.
5. Si terminó bien, la corrida queda en verde, y su **Summary** muestra `Prepare` y `Train` en `Succeeded`. Si algo
   falla, el motivo sale en esa misma tabla (`FailureReason`) o en el log del paso en rojo.

Lo mismo desde la terminal (igual hay que aprobarlo en la web):

```bash
gh workflow run train_pipeline_manual.yml -R ana/vantix --ref main -f ingest_date=2025-04-30 \
  -f snapshot_date=2025-04-30 -f window_days=30 -f k_min=2 -f k_max=10 -f keep_mlflow_on=true
```

| Si ves esto… | Casi siempre es… |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `github_repo` mal escrito ([Paso 2 · Autorizar tu repo](#paso-2--autorizar-tu-repo-para-que-github-actions-pueda-entrar-a-aws)) o no se volvió a correr `make up-training` |
| `Could not load credentials` o un valor vacío | falta una variable ([2. Conectar GitHub con tu AWS](#2-conectar-github-con-tu-aws-obligatorio)) o se cargó fuera del environment `production` |
| `MLflow no respondió en …` | `MLFLOW_TRACKING_URI` no es la URL actual ([2. Conectar GitHub con tu AWS](#2-conectar-github-con-tu-aws-obligatorio)) o el servidor no está levantado ([1. Infraestructura](#1-infraestructura-iac-infrastructure-as-code)) |
| `ResourceLimitExceeded` | cuota de cómputo de AWS SageMaker insuficiente para `ml.t3.xlarge` ([Paso 4 · Preparar GitHub y la cuota de cómputo de AWS SageMaker](#paso-4--preparar-github-y-la-cuota-de-cómputo-de-aws-sagemaker)) |
| Prepare falla porque no encuentra datos | `ingest_date` no coincide con el `INGEST_DATE` que usaste en [3. Datos a S3](#3-datos-a-s3) |

## 5. Elegir k y promover (desde GitHub Actions)

1. Entra a MLflow: `make mlflow-status` muestra la URL; usuario `admin`, contraseña con `make mlflow-server-password`.
   (Si está apagado: `make mlflow-start`.)
2. Abre el experimento `vantix-segmentation`. Hay un run padre por corrida y un run hijo por cada k. Compara sus
   métricas y los perfiles de los grupos (artefacto `profile/`), elige un k y copia el **Run ID** de su run hijo.
3. Ponle nombre a los grupos en `segment_maps/<snapshot_date>_k<k>.json` (ejemplo: `segment_maps/2025-04-30_k5.json`)
   y súbelo a `main` por PR. Revisa en el perfil que cada número de grupo corresponda a su nombre, aunque uses el
   archivo de ejemplo.
4. **Actions** → **promote_best_model_manual** → **Run workflow** (rama `main`):

   | Campo | Qué poner |
   |---|---|
   | `run_id` | el Run ID del paso 2 |
   | `segment_map` | el archivo del paso 3, p. ej. `segment_maps/2025-04-30_k5.json` |
   | `reason` | por qué lo eliges, p. ej. `primer champion` |

5. Apruébalo igual que en la sección [4. Entrenar](#4-entrenar-desde-github-actions) (**Review deployments**). Al terminar, el modelo queda con el alias `@champion` y
   exportado a `s3://vantix-<cuenta>-data/models/champion/`, de donde lo lee la inferencia.
6. Apaga MLflow: `make mlflow-stop`.

Volver a una versión anterior: **Actions** → **rollback_model_manual** (`version`, `reason`).
