# Plan: setup global automatizado

Estado: **fases 1 a 3 hechas** (`setup/common/`, `.env`, `run.sh`, `train-*` e `inference-*`). Sigue la fase 4.

## 1. Objetivo y regla principal

Que un especialista llene un `.env`, corra `make train-up` y vea en pantalla cómo se levanta el sistema desde cero. Lo
mismo con `inference` y `monitoring`.

**Es una refactorización.** La lógica y el orden son los de los `paso*.sh` que ya existen y se probaron. Se reorganiza,
se modulariza y se centraliza; no se reescribe ni se agregan pasos.

Lo único que cambia de comportamiento:

| Cambio | Motivo |
|---|---|
| Los datos salen de `.env`, no de opciones ni de preguntas | una sola fuente, validada al inicio |
| Los pasos se encadenan solos | hoy se lanzan uno por uno |
| Menos `[y/n]` (sección 6) | preguntar solo en lo crucial |
| La cuenta de AWS se compara con `ACCOUNT_ID` | no tocar la cuenta equivocada |
| `*-check` y `*-down` | comandos nuevos que reutilizan lógica existente (sección 3) |

**Fuera de alcance:** entrenar, promover, desplegar el pipeline, puntuar y correr el monitoreo (siguen en GitHub Actions
con aprobación), el código de los pipelines y los módulos de Terraform.

## 2. Por qué

- 20 scripts y ~6.000 líneas. `confirm` y `title` están copiadas en 20 archivos; `spin` y `stage`, en 19; `check_aws`,
  en 15 (con 3 versiones). Un arreglo común obliga a tocar muchos archivos.
- Hay que lanzar los scripts uno por uno y responder `[y/n]` en casi todos.

## 3. Comandos

| Comando | Qué hace | Lógica que reutiliza |
|---|---|---|
| `make train-up` | training 1 a 11 | `pipelines/training/setup/` |
| `make inference-up` | inference 1 a 3 | `pipelines/inference/setup/` |
| `make monitoring-up` | monitoring 1 a 4 | `monitorization/setup/` |
| `make <sistema>-check` | solo lee: qué está listo y qué falta | la etapa "Revisar qué tienes" de cada paso |
| `make train-down` | apaga la EC2 de MLflow | `make mlflow-stop` |
| `make inference-down` | apaga el scheduler semanal | inference 6 con `--estado=off` |
| `make monitoring-down` | apaga la EC2 de monitoreo | `make stop` de `monitorization/` |

- `down` **no borra nada**; la IP y los discos se siguen cobrando (~USD 5 a 6/mes por EC2).
- Los pasos opcionales quedan como comandos aparte: scheduler (inference 6) y lote de prueba (monitoring 6).

**Orden desde cero:** `train-up` → entrenar y promover (GitHub Actions) → `inference-up` → `monitoring-up`. Igual que hoy,
el paso 1 de inferencia y el de monitoreo exigen el `@champion`: si no existe, se detienen y dicen qué falta.

## 4. Estructura

```
Makefile              secciones por sistema; solo llama a setup/run.sh
.env.example          plantilla versionada (.env no se sube)
setup/
  run.sh              valida .env y encadena los pasos en orden
  common/             lo que hoy está copiado, una sola vez
    ui.sh             stage, title, ok, err, spin, confirm, log
    env.sh            lee y valida .env
    aws.sh            sesión, cuenta, bucket del estado, champion, lotes
    github.sh         sesión, repo, environment, variables
    terraform.sh      init, plan, show, apply, tfvars
    server.sh         imagen en ECR, encender, apagar y espera de /health (MLflow y monitoreo)
    step.sh           lo que carga cada paso: revisar → configurar → comprobar
  training/           01_tools … 11_github_vars
  inference/          01_check … 03_github_vars, 06_schedule_on
  monitoring/         01_check … 04_github_vars, 06_sample_batch
  <sistema>/system.sh variables obligatorias, orden de los pasos, costo y siguiente acción
  logs/               detalle de cada ejecución (no se sube)
```

| Nuevo | Viene de | Nuevo | Viene de |
|---|---|---|---|
| `training/01_tools` | training 1 | `training/10_upload_data` | training 10 |
| `training/02_aws_session` | training 2 | `training/11_github_vars` | training 11 |
| `training/03_python` | training 3 | `inference/01_check` | inference 1 |
| `training/04_github_repo` | training 4 | `inference/02_infra` | inference 2 |
| `training/05_dataset` | training 5 | `inference/03_github_vars` | inference 3 |
| `training/06_environment_quota` | training 6 | `inference/06_schedule_on` y `down` | inference 6 |
| `training/07_state_bucket` | training 7 | `monitoring/01_check` | monitoring 1 |
| `training/08_mlflow` | training 8 | `monitoring/02_config` | monitoring 2 |
| `training/09_infra` | training 9 | `monitoring/03_infra` | monitoring 3 |
| | | `monitoring/04_github_vars` · `06_sample_batch` | monitoring 4 · 6 |

Cada paso conserva sus etapas: revisar → configurar → comprobar. Sigue en bash 3.2 y GNU Make 3.81, los de macOS.

## 5. `.env`: configuración, nunca credenciales

| Variable | La usa | Opción que reemplaza | `train` | `inference` | `monitoring` |
|---|---|---|:-:|:-:|:-:|
| `SSO_START_URL` · `SSO_REGION` · `ROLE_NAME` | training 2 | `--sso-start-url` · `--sso-region` · `--role-name` | ✔ | – | – |
| `ACCOUNT_ID` | todos | `--account-id` | ✔ | ✔ | ✔ |
| `PROFILE` | todos | `--profile` | ✔ | ✔ | ✔ |
| `GITHUB_REPO` (`usuario/repo`) | todos | `--repo` | ✔ | ✔ | ✔ |
| `INGEST_DATE` | training 10 | `--ingest-date` | ✔ | – | – |
| `ALERT_EMAIL` | monitoring 2 | `--alert-email` | – | – | ✔ |

Es lo **primero** que hace cualquier `up`, antes de tocar tu máquina, AWS o GitHub:

1. Si no hay `.env`, dice `cp .env.example .env` y **se detiene**.
2. Comprueba que estén **todas** las variables del sistema y que tengan un formato válido.
3. Si falta o está mal aunque sea una, las lista **todas juntas** y **se detiene**:

```
✘ .env incompleto (2 problemas):
    SSO_START_URL   falta
    ACCOUNT_ID      debe tener 12 dígitos
  Corrígelo y vuelve a correr: make train-up
```

- Los inicios de sesión ocurren en el navegador; los tokens los guardan `aws` y `gh`.
- Si contiene llaves o tokens (`AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`…), se detiene y explica por qué.
- Se lee con una lista de claves permitidas; **no se ejecuta** con `source`.
- Si la cuenta de la sesión no es `ACCOUNT_ID`, se detiene.

## 6. Flujo de `up` y confirmaciones

1. Valida `.env`; si algo falta, se detiene.
2. Informa cuenta, repo, pasos que correrá, tiempo aproximado y qué cobra. **Pide una confirmación.**
3. Corre los pasos en orden. En cada uno: si ya está listo, lo dice y sigue; si falta, lo configura y lo comprueba.
4. Si un paso falla, se detiene con el motivo. Al repetir el comando, continúa desde lo que falte.
5. Al terminar, dice la siguiente acción (p. ej. cómo entrenar).

| Situación | Qué hace |
|---|---|
| Crear recursos, descargar, subir un lote, encender MLflow | informa y sigue |
| Iniciar sesión en AWS o GitHub | informa y abre el navegador |
| Instalar programas en tu máquina o borrar `.venv` | informa y **pregunta** |
| Cambiar una variable o un `production` que ya existen | muestra antes y después, y **pregunta** |
| Pedir un aumento de cuota a AWS | informa y **pregunta** |
| Terraform reemplaza o destruye algo | muestra el plan y **pregunta** |
| Terraform destruye datos (buckets, disco de monitoreo) | **se detiene** (hoy solo lo hace monitoring 3) |

## 7. Qué se ve en pantalla

```
Entrenamiento · cuenta <id> · repo ana/vantix
[ 8/11] MLflow
        → Creando la infraestructura… 2 min 10 s
        ✔ EC2: este script la encendió
        ✔ MLflow: encendido y respondiendo
[ 9/11] Infraestructura de entrenamiento
        ✔ Ya estaba lista
```

Una línea por acción, en tiempo real. La salida completa va a `setup/logs/`, sin contraseñas ni tokens; si algo falla, se
muestra el error y la ruta del log.

## 8. Fases

Cada fase es un PR. Los `paso*.sh` de cada sistema **se conservan como respaldo** por si esto sale mal; borrarlos es una
decisión aparte.

| Fase | Entrega | Se acepta si… |
|---|---|---|
| 0 | PR con lo actual, en una rama nueva desde `main` (el PR #17 ya se mergeó); `HANDOFF.md` al día | CI en verde |
| 1 | `common/`, `.env` y `run.sh`, con pruebas simuladas | `.env` incompleto o cuenta equivocada lo detienen |
| 2 | `train-*` y su guía | en la cuenta actual no cambia nada la segunda vez |
| 3 | `inference-*` y su guía | igual, y respeta el estado del scheduler |
| 4 | `monitoring-*` y su guía | igual, y protege disco y respaldos |
| 5 | Makefile ordenado y prueba completa | **desde cero: carpeta, repo y cuenta de AWS nuevos** |

La cuenta actual **no se destruye** para probar.

## 9. Decisiones tomadas

1. `up-*`, `down-*` y `down-all` **se quitaron del `Makefile`**: duplicaban lo nuevo, y `down-inference`, `down-shared` y
   `down-all` borraban datos (`force_destroy = true` en los buckets). `schedule-on/off` ahora llaman a inference 6.
2. Los `paso*.sh` se conservan como respaldo.
3. La prueba desde cero se hace aislada, sin tocar lo actual:

| Qué | Con qué |
|---|---|
| Carpeta | clone nuevo en otra ruta (sin `.env`, `.venv`, `tfvars`, datos ni `.terraform`) |
| GitHub | repo de prueba nuevo, p. ej. `vantix-prueba`: usar el actual sobrescribiría las variables y `production` |
| AWS | member account nueva con otro `PROFILE`; su cuota de `ml.t3.xlarge` puede ser 0 y tardar en aprobarse |
| Sesiones | `gh auth logout` y un perfil de AWS sin crear, para probar los inicios de sesión |
| Herramientas | no se prueban en esta máquina, que ya las tiene: hace falta otra Mac o una máquina virtual |
