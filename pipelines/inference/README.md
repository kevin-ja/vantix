# Sistema de Inferencia

Pipeline `vantix-inference` en SageMaker: toma un lote de apuestas, calcula las features de cada cliente y le asigna un
segmento con el modelo `@champion`. **No entrena**: usa el modelo que se promovió. MLflow puede estar apagado.

# Setup del sistema

La guía va del Paso 0 al 6, en orden. Los pasos 1 al 3 preparan todo y se hacen **una sola vez**, con los scripts de
[`setup/`](setup/). Los pasos 4 y 5 se repiten cuando cambia el código o hay que puntuar.

| Paso | Qué se logra | Cómo | Dónde actúa |
|---|---|---|---|
| [0](#paso-0--completar-el-setup-de-entrenamiento) | Todo lo compartido y un `@champion` | guía de entrenamiento | — |
| [1](#paso-1--comprobar-los-requisitos) | Saber que no falta nada | `paso1.sh` | solo lee |
| [2](#paso-2--levantar-la-infraestructura) | Bucket de scores, rol y scheduler apagado | `paso2.sh` | AWS |
| [3](#paso-3--conectar-github-con-la-infraestructura) | GitHub sabe a qué AWS conectarse | `paso3.sh` | GitHub |
| [4](#paso-4--desplegar-el-pipeline) | Pipeline en SageMaker | GitHub Actions | AWS |
| [5](#paso-5--puntuar) | Segmento de cada cliente | GitHub Actions | AWS 💰 |
| [6](#paso-6--corrida-semanal-opcional) | Corrida semanal automática | `paso6.sh` | AWS 💰 |

💰 = cobra mientras corre.

**Cómo se comportan los scripts:** igual que los de entrenamiento. Revisan, muestran qué falta, preguntan `[y/n]` y
comprueban el resultado. Sin una `y` no cambian nada, repetirlos es seguro y no piden credenciales.

Los comandos se corren **desde la raíz del repo**. Si tu perfil de AWS no se llama `vantix`, agrega `--profile=NOMBRE`.

### Paso 0 · Completar el setup de entrenamiento

**Por qué:** la inferencia reutiliza sus herramientas, sesiones, infraestructura y datos, y necesita un modelo promovido.

Completa los pasos 0 al 13 de [`pipelines/training/README.md`](../training/README.md).

### Paso 1 · Comprobar los requisitos

**Por qué:** es más fácil corregir lo que falta ahora que entender un error a mitad de camino.

```bash
bash pipelines/inference/setup/paso1.sh
```

**Qué hace:** solo lee. Comprueba GitHub, AWS, que el `@champion` tenga sus 4 archivos y que haya datos en `raw/`. Si
falta algo, dice qué paso correr.

### Paso 2 · Levantar la infraestructura

**Por qué:** los scores van a un bucket propio, separado de los datos. Así quien los consume no necesita acceso a las
apuestas.

```bash
bash pipelines/inference/setup/paso2.sh
```

**Qué hace:** aplica `infra/shared` y después `infra/inference`, mostrando los cambios de cada uno.

| Recurso | Archivo | Permisos |
|---|---|---|
| Bucket `vantix-<cuenta>-scores` (versionado, cifrado, privado) | `infra/inference/main.tf` | — |
| Rol `vantix-inference-exec` (lo usa el job) | `infra/inference/main.tf` | leer `raw/` y `models/champion/`, escribir scores, jobs de SageMaker, imagen sklearn de ECR, logs |
| Scheduler `vantix-inference-weekly` y su rol | `infra/inference/main.tf` | solo lanzar `vantix-inference` |
| Roles `vantix-github-deploy-inference` y `vantix-github-batch-inference` | `infra/shared/github.tf` | uno solo despliega el pipeline; el otro solo lo ejecuta |

El scheduler se crea **apagado**. Si ya existe, el script lo deja como está.

### Paso 3 · Conectar GitHub con la infraestructura

**Por qué:** los workflows de inferencia necesitan 4 variables más en `production`; el setup de entrenamiento solo carga
las suyas. No son secretos.

```bash
bash pipelines/inference/setup/paso3.sh
```

**Qué hace:** lee los valores de la infraestructura, los guarda en GitHub y comprueba que AWS confía en tu repo.

### Paso 4 · Desplegar el pipeline

**Por qué:** crea en SageMaker el pipeline con el código de `main`. Solo lo despliega, no lo ejecuta: así desplegar y
puntuar son decisiones separadas.

1. **Actions** → **deploy_inference** → **Run workflow** → `ref` = `main`.
2. Ábrela → **Review deployments** → marca `production` → **Approve and deploy**.

Lo mismo desde la terminal (cambia `ana/vantix` por tu repo; igual se aprueba en la web):

```bash
gh workflow run deploy_inference.yml -R ana/vantix --ref main -f ref=main
gh run watch -R ana/vantix     # opcional: elige la corrida y síguela
```

`--ref` es la rama de donde sale el workflow; `-f ref`, el código que se despliega.

Después se lanza solo al mergear cambios en `pipelines/inference/` (excepto `setup/` y archivos `.md`), y también espera
aprobación. Para volver a un código anterior, lánzalo a mano con `ref` = ese commit.

### Paso 5 · Puntuar

**Por qué con fechas explícitas:** `auto` usa el último lote y la fecha de hoy. Con datos históricos la corrida falla,
porque exige que el lote llegue hasta `snapshot_date`.

1. **Actions** → **batch_inference_manual** → **Run workflow**, con la rama `main`:

   | Campo | Qué es | Con el dataset de la guía |
   |---|---|---|
   | `ingest_date` | lote que se puntúa | `2025-04-30` |
   | `snapshot_date` | día de corte de las features | `2025-04-30` |
   | `scoring_date` | fecha con la que se guardan los scores | `2025-05-01` |
   | `window_days` | días hacia atrás; **el mismo que se usó al entrenar** | `30` |

2. Apruébala igual que en el [Paso 4](#paso-4--desplegar-el-pipeline). Tarda unos 3 min.
3. El **Summary** muestra `Succeeded` y el contenido de `latest.json`.

**Salida**, en `s3://vantix-<cuenta>-scores/scores/`:

| Archivo | Qué es |
|---|---|
| `scoring_date=<fecha>/scores.parquet` | el segmento de cada cliente |
| `scoring_date=<fecha>/summary.json` | datos, modelo y commit usados, y conteos |
| `latest.json` | apunta a los scores más recientes; lo lee la API de campañas |

🚨 Cada corrida actualiza `latest.json`, también una de prueba.

| Si ves esto… | Casi siempre es… |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | AWS no confía en tu repo: [Paso 4 de entrenamiento](../training/README.md#paso-4--autorizar-tu-repo-en-aws-oidc) y después el [Paso 2](#paso-2--levantar-la-infraestructura) |
| `Could not load credentials` o un valor vacío | faltan variables: [Paso 3](#paso-3--conectar-github-con-la-infraestructura) |
| El pipeline `vantix-inference` no existe | falta desplegarlo: [Paso 4](#paso-4--desplegar-el-pipeline) |
| `datos desactualizados` | el lote no llega hasta `snapshot_date`: revisa las fechas de este paso |
| `ResourceLimitExceeded` | cuota de cómputo de AWS SageMaker: [Paso 6 de entrenamiento](../training/README.md#paso-6--environment-production-y-cuota-de-cómputo-de-aws-sagemaker) |

### Paso 6 · Corrida semanal (opcional)

**Por qué es opcional:** solo sirve si cada semana llega un lote nuevo a `raw/`. Corre **sin aprobación** y con `auto`.

```bash
bash pipelines/inference/setup/paso6.sh --estado=on      # cada lunes 06:00 UTC
bash pipelines/inference/setup/paso6.sh --estado=off
```

**Qué hace:** para encenderla exige que la última corrida haya terminado bien y muestra qué lote usaría. Apagarla nunca
se bloquea.

⚠️ `make up-inference` la vuelve a apagar; `paso2.sh`, no.
