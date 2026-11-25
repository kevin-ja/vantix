# Sistema de Entrenamiento

Pipeline `vantix-training` en SageMaker: **Prepare** (features RFM por usuario) → **Train** (preprocesador + KMeans
por cada k + métricas → MLflow). Después, una persona elige k y **promueve** el run como `@champion`.

## 1. Componentes
## 2. Funciones de cada componente
## 3. Relacion entre los componentes
## 4. Pipeline de Entrenamiento
## 5. MLOps 

# Setup del sistema

La guía va del Paso 0 al 13, en orden: cada paso necesita los anteriores. Los pasos 1 al 11 preparan todo y se hacen
**una sola vez**, cada uno con un script de [`setup/`](setup/). Los pasos 12 y 13 se repiten cada vez que se entrena.

| Paso | Qué hace | Cómo | Dónde actúa |
|---|---|---|---|
| [0](#paso-0--tener-tu-propia-copia-del-repo) | Clona/Descarga el reporsitorio | GitHub y `git clone` | GitHub, tu máquina |
| [1](#paso-1--instalar-las-herramientas) | Verifica que tu maquina local tenga instalada herramientas del CLI a usar | `paso1.sh` | tu máquina |
| [2](#paso-2--entrar-a-aws) | Se logea en una cuenta de AWS | `paso2.sh` | tu máquina |
| [3](#paso-3--crear-el-entorno-de-python) | Crea un Virtual Env. en tu maquina local | `paso3.sh` | tu máquina |
| [4](#paso-4--autorizar-tu-repo-en-aws-oidc) | Autoriza tu repo en AWS (OIDC) | `paso4.sh` | tu máquina |
| [5](#paso-5--descargar-el-dataset) | Descarga el dataset de entrenamiento  | `paso5.sh` | tu máquina |
| [6](#paso-6--environment-production-y-cuota-de-cómputo-de-aws-sagemaker) | Aprobaciones y cuota de cómputo | `paso6.sh` | GitHub, AWS |
| [7](#paso-7--crear-el-bucket-del-estado-de-terraform) | Bucket del estado de Terraform | `paso7.sh` | AWS |
| [8](#paso-8--levantar-mlflow) | Servidor de MLflow | `paso8.sh` | AWS 💰 |
| [9](#paso-9--levantar-la-infraestructura-de-entrenamiento) | Bucket de datos, roles y permisos | `paso9.sh` | AWS |
| [10](#paso-10--subir-el-dataset-a-s3) | Dataset en S3 | `paso10.sh` | AWS |
| [11](#paso-11--conectar-github-con-aws) | GitHub sabe a qué AWS conectarse | `paso11.sh` | GitHub |
| [12](#paso-12--entrenar) | Modelos entrenados | GitHub Actions | AWS 💰 |
| [13](#paso-13--elegir-k-y-promover) | Un modelo en uso (`@champion`) | GitHub Actions | AWS |

💰 = cobra mientras está en uso.

## Camino rápido: los pasos 1 al 11 con un comando

Después del [Paso 0](#paso-0--tener-tu-propia-copia-del-repo):

```bash
cp .env.example .env     # complétalo: no lleva contraseñas, llaves ni tokens
make train-up
```

`make train-up` revisa el `.env`; si falta o está mal un solo dato, lo dice y se detiene sin tocar nada. Después informa,
pide una confirmación y corre los pasos en orden. Solo vuelve a preguntar antes de instalar programas, cambiar algo que
ya existe, reemplazar o destruir recursos, o pedir cuota a AWS. Si se detiene, corrige y repite: continúa donde quedó. El
detalle queda en `setup/logs/`.

| Comando | Qué hace |
|---|---|
| `make train-check` | solo lee: qué está listo y qué falta |
| `make train-down` | 💰 apaga la EC2 de MLflow; no borra nada |

Sigue en el [Paso 12](#paso-12--entrenar). Lo de abajo explica cada paso; sus `paso*.sh` hacen lo mismo uno por uno y se
conservan como respaldo.

## Paso a paso

**Cómo se comportan los scripts:** revisan qué tienes, muestran qué falta, preguntan `[y/n]` y comprueban el resultado.
Sin una `y` no cambian nada (excepción: el Paso 8 enciende MLflow si está apagado), y repetirlos es seguro: solo hacen
lo que falta. Ninguno pide contraseñas, tokens ni llaves; los inicios de sesión ocurren en el navegador. Si uno se
detiene, dice el motivo y qué paso correr.

**Sistema operativo:** `paso1.sh` y `paso2.sh` son solo para macOS. Los demás se probaron en macOS. En Windows usa WSL2,
porque el proyecto necesita Linux o macOS.

En los ejemplos, tu usuario de GitHub es `ana` y tu repo se llama `vantix`. Los comandos se corren **desde la raíz del
repo**. Si tu perfil de AWS no se llama `vantix`, agrega `--profile=NOMBRE` desde el Paso 6 (y en el Paso 2).

### Paso 0 · Tener tu propia copia del repo

**Por qué:** el entrenamiento corre desde *tu* GitHub, y cada modelo registra el commit del código que lo entrenó. Esa
trazabilidad solo sirve si el código está en un repo tuyo.

1. En el [repo original](https://github.com/kevin-ja/vantix), pulsa **Fork**. Se crea `github.com/ana/vantix`.
2. En tu fork, abre **Actions** y pulsa **"I understand my workflows, go ahead and enable them"**: GitHub los apaga en
   los forks.
3. Descárgalo (solo necesitas [Git](https://git-scm.com/downloads)):
   ```bash
   git clone https://github.com/ana/vantix.git
   cd vantix
   ```

### Paso 1 · Instalar las herramientas

**Por qué:** los demás pasos las usan, y algunas deben tener una versión concreta.

```bash
bash pipelines/training/setup/paso1.sh
```

**Qué hace:** revisa cada herramienta y su versión, e instala o actualiza solo lo que falte. Docker Desktop se abre a
mano la primera vez, para aceptar su licencia.

<details>
<summary>Sin macOS: instálalas a mano</summary>

| Herramienta | Para qué | Comprobar | Debe mostrar |
|---|---|---|---|
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | entrar a AWS | `aws --version` | `aws-cli/2.…` |
| [Terraform 1.15.8](https://releases.hashicorp.com/terraform/1.15.8/) | crear la infraestructura | `terraform version` | `Terraform v1.15.8` (exactamente esa versión) |
| [Docker](https://docs.docker.com/get-started/get-docker/) | construir la imagen de MLflow | `docker buildx version` | una versión, sin error |
| [uv](https://docs.astral.sh/uv/getting-started/installation/) | crear el entorno de Python | `uv --version` | `uv …` |
| [GitHub CLI](https://cli.github.com/) | configurar tu repo de GitHub | `gh --version` | `gh version 2.40` o mayor |
| [Git](https://git-scm.com/downloads) | descargar el repo | `git --version` | `git version …` |
| Make | encender y apagar MLflow | `make --version` | `GNU Make 3.81` o mayor |

</details>

### Paso 2 · Entrar a AWS

**Por qué:** todo se crea en tu cuenta de AWS. Debe usarse una **member account** a la que se accede con **SSO** (IAM
Identity Center):

- **Member account:** mantiene los recursos, los costos y las cuotas de Vantix separados de tus otros proyectos.
- **SSO:** inicias sesión en el navegador y AWS te da credenciales temporales, sin llaves fijas en tu máquina.

No se recomienda usar la *management account* de la organización, ni el usuario root, ni un IAM user con llaves fijas.

```bash
# La primera vez (crea el perfil; lo que no pases, te lo pregunta):
bash pipelines/training/setup/paso2.sh \
  --sso-start-url=https://mi-portal.awsapps.com/start \
  --sso-region=us-east-1 \
  --account-id=123456789012 \
  --role-name=AdministratorAccess

# Después, cuando venza la sesión:
bash pipelines/training/setup/paso2.sh
```

Esos datos no son secretos. Están en tu portal de AWS: elige la cuenta → **Access keys** → IAM Identity Center.

**Qué hace:** crea el perfil `vantix` en `~/.aws/config` (región `us-east-1`), inicia sesión, enciende Docker y comprueba
que entraste a la cuenta correcta. El rol debe tener permisos de administrador, porque Terraform crea roles.

<details>
<summary>Sin macOS: hazlo a mano</summary>

```bash
aws configure sso --profile vantix      # una sola vez; región us-east-1
aws sso login --profile vantix          # cuando venza la sesión
aws sts get-caller-identity --profile vantix --query Account --output text   # debe mostrar tu número de cuenta
```

Además, Docker debe estar encendido.

</details>

### Paso 3 · Crear el entorno de Python

**Por qué:** verificar y subir el dataset usa Python, con las versiones que fija el proyecto.

```bash
bash pipelines/training/setup/paso3.sh
```

**Qué hace:** crea `.venv/` con Python 3.11 e instala `requirements-dev.txt`.

### Paso 4 · Autorizar tu repo en AWS (OIDC)

**Por qué:** los workflows entran a AWS sin contraseñas, con OIDC: AWS solo deja pasar al repo que Terraform tenga
anotado. Viene anotado el repo original, así que hay que poner el tuyo **antes** de crear la infraestructura.

```bash
bash pipelines/training/setup/paso4.sh
```

**Qué hace:** inicia sesión en GitHub si hace falta, pregunta a GitHub cómo se identifica tu repo y lo guarda como
`github_repo` en `infra/shared/terraform.tfvars` y `monitorization/infra/terraform.tfvars` (no se suben a git).

Si ya habías creado la infraestructura con otro valor, repite el Paso 9 para que AWS lo use. Para el monitoreo:
`cd monitorization && make up`.

### Paso 5 · Descargar el dataset

**Por qué:** el dataset no está en git. Está en el Release
[`data-v1`](https://github.com/kevin-ja/vantix/releases/tag/data-v1) del repo original: 842.163 apuestas y 19 columnas,
explicadas en [`data/diccionario.txt`](../../data/diccionario.txt).

```bash
bash pipelines/training/setup/paso5.sh
```

**Qué hace:** descarga `data/data.parquet` (~20 MB) y comprueba que llegó completo (SHA-256) y que cumple las mismas
reglas que exige el pipeline.

### Paso 6 · Environment `production` y cuota de cómputo de AWS SageMaker

**Por qué:**
- **Environment:** los workflows corren dentro de `production`. AWS solo deja entrar a los jobs de ese environment, y
  cada corrida espera a que una persona la apruebe.
- **Cuota:** AWS limita cuántas máquinas puedes usar. Hace falta al menos **1** `ml.t3.xlarge` en *Processing jobs*.

```bash
bash pipelines/training/setup/paso6.sh
```

**Qué hace:** crea el environment contigo como aprobador y revisa la cuota. Si es 0, ofrece pedir el aumento; AWS decide
si lo aprueba y cuándo. La cuota de *Training jobs* no hace falta: hoy Train corre como Processing job.

### Paso 7 · Crear el bucket del estado de Terraform

**Por qué:** la infraestructura se crea como código (**IaC**) con Terraform, que necesita recordar qué creó. Ese registro
se guarda en S3 para no perderlo ni depender de tu máquina.

```bash
bash pipelines/training/setup/paso7.sh
```

**Qué hace:** crea el bucket `vantix-<cuenta>-tfstate`, versionado y sin acceso público.

### Paso 8 · Levantar MLflow

**Por qué:** MLflow guarda las métricas y los modelos de cada entrenamiento. Va antes que el Paso 9, que lee su URL.

```bash
bash pipelines/training/setup/paso8.sh
```

**Qué hace:** construye la imagen, la sube a ECR y crea el servidor (EC2 + CloudFront); muestra los cambios antes de
aplicarlos. Si el servidor ya existe pero está apagado, lo **enciende sin preguntar** y lo informa. Termina solo cuando
MLflow responde. Detalle: [`mlflow_server/README.md`](../../mlflow_server/README.md).

💰 La EC2 queda **encendida**: apágala con `make mlflow-stop`. El workflow de entrenamiento la enciende solo.

### Paso 9 · Levantar la infraestructura de entrenamiento

**Por qué:** crea dónde viven los datos y quién puede hacer qué. Cada rol tiene solo los permisos de su tarea.

```bash
bash pipelines/training/setup/paso9.sh
```

**Qué hace:** aplica `infra/shared` y después `infra/training`, mostrando los cambios de cada uno.

| Recurso | Archivo | Permisos |
|---|---|---|
| Bucket de datos `vantix-<cuenta>-data` (versionado, cifrado, privado) | `infra/shared/main.tf` | — |
| Rol `vantix-training-exec` (lo usan los jobs) | `infra/training/main.tf` | S3 del bucket de datos, jobs de SageMaker, imágenes sklearn de ECR, logs, contraseña de MLflow en SSM |
| Proveedor OIDC de GitHub + rol `vantix-github-train` | `infra/shared/github.tf` | crear/actualizar/ejecutar `vantix-training`, pasar el rol de ejecución, encender/apagar la EC2 de MLflow |
| Rol `vantix-github-promote` | `infra/shared/github.tf` | contraseña de MLflow, leer `models/`, escribir `models/champion/`, encender/apagar la EC2 de MLflow |

Los roles de GitHub solo los asumen workflows de tu repo que corren en el environment `production`.

### Paso 10 · Subir el dataset a S3

**Por qué:** SageMaker lee los datos de S3, no de tu máquina.

```bash
bash pipelines/training/setup/paso10.sh                              # lote 2025-04-30
bash pipelines/training/setup/paso10.sh --ingest-date=2025-05-31     # otra etiqueta de lote
```

**Qué hace:** verifica el dataset otra vez y lo sube a `raw/ingest_date=<fecha>/`. Anota esa fecha: la pedirá el Paso 12.
Un lote **no se puede sobrescribir**, así siempre se sabe con qué datos se entrenó cada modelo.

### Paso 11 · Conectar GitHub con AWS

**Por qué:** los workflows no saben cuál es tu bucket, tus roles ni tu MLflow. Se les dice con 6 variables en
`production`. No son secretos: las contraseñas siguen en AWS (SSM).

```bash
bash pipelines/training/setup/paso11.sh
```

**Qué hace:** lee los valores de la infraestructura, los guarda en GitHub y comprueba que AWS confía en tu repo.
Repítelo si vuelves a crear el servidor de MLflow, porque su URL puede cambiar.

### Paso 12 · Entrenar

**Por qué desde GitHub y sin script:** cada corrida queda registrada (quién, con qué parámetros y qué resultado) y una
persona la aprueba antes de gastar.

1. En tu repo: **Actions** → **train_pipeline_manual** → **Run workflow**, con la rama `main`:

   | Campo | Qué es | La primera vez |
   |---|---|---|
   | `ingest_date` | lote que se lee (el del [Paso 10](#paso-10--subir-el-dataset-a-s3)) | `2025-04-30` |
   | `snapshot_date` | día de corte de las features | `2025-04-30` |
   | `window_days` | días hacia atrás desde el corte | `30` |
   | `k_min`, `k_max` | rango de cantidad de grupos que se prueba | `2`, `10` |
   | `keep_mlflow_on` | dejar MLflow encendido al terminar | **marcado** (se usa en el [Paso 13](#paso-13--elegir-k-y-promover)) |

2. La corrida queda en **Waiting**: ábrela → **Review deployments** → marca `production` → **Approve and deploy**.
3. Espera (~35 min con k de 2 a 10). El workflow enciende MLflow, crea o actualiza el pipeline `vantix-training` en
   SageMaker, lo ejecuta y espera el resultado.
4. Si termina en verde, el **Summary** muestra `Prepare` y `Train` en `Succeeded`.

Lo mismo desde la terminal (igual se aprueba en la web):

```bash
gh workflow run train_pipeline_manual.yml -R ana/vantix --ref main -f ingest_date=2025-04-30 \
  -f snapshot_date=2025-04-30 -f window_days=30 -f k_min=2 -f k_max=10 -f keep_mlflow_on=true
```

| Si ves esto… | Casi siempre es… |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | AWS no confía en tu repo: [Paso 4](#paso-4--autorizar-tu-repo-en-aws-oidc) y después [Paso 9](#paso-9--levantar-la-infraestructura-de-entrenamiento) |
| `Could not load credentials` o un valor vacío | faltan variables: [Paso 11](#paso-11--conectar-github-con-aws) |
| `MLflow no respondió en …` | la URL cambió ([Paso 11](#paso-11--conectar-github-con-aws)) o el servidor no existe ([Paso 8](#paso-8--levantar-mlflow)) |
| `ResourceLimitExceeded` | cuota de cómputo de AWS SageMaker insuficiente: [Paso 6](#paso-6--environment-production-y-cuota-de-cómputo-de-aws-sagemaker) |
| Prepare no encuentra datos | `ingest_date` no es el del [Paso 10](#paso-10--subir-el-dataset-a-s3) |

### Paso 13 · Elegir k y promover

**Por qué lo decide una persona:** las métricas no dicen si los grupos sirven al negocio. Promover es lo que pone un
modelo en uso: la inferencia solo lee el `@champion`.

1. Entra a MLflow: `make mlflow-status` muestra la URL; usuario `admin`, contraseña con `make mlflow-server-password`.
   Si está apagado: `make mlflow-start`.
2. En el experimento `vantix-segmentation` hay un run hijo por cada k. Compara sus métricas y perfiles (artefacto
   `profile/`), elige uno y copia su **Run ID**.
3. Nombra los grupos en `segment_maps/<snapshot_date>_k<k>.json` (ejemplo: `segment_maps/2025-04-30_k5.json`) y súbelo a
   `main` por PR. Revisa en el perfil que cada número corresponda a su nombre, aunque uses el ejemplo.
4. **Actions** → **promote_best_model_manual** → **Run workflow** (rama `main`), y apruébalo como en el
   [Paso 12](#paso-12--entrenar):

   | Campo | Qué poner |
   |---|---|
   | `run_id` | el Run ID elegido |
   | `segment_map` | el archivo con los nombres, p. ej. `segment_maps/2025-04-30_k5.json` |
   | `reason` | por qué lo eliges, p. ej. `primer champion` |

   El modelo queda como `@champion` y se exporta a `s3://vantix-<cuenta>-data/models/champion/`.
5. 💰 Apaga MLflow: `make mlflow-stop`.

Para volver a una versión anterior: **Actions** → **rollback_model_manual** (`version`, `reason`).
