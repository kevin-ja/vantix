# Sistema de Monitorización

Compara cada lote nuevo con los datos con los que se entrenó el `@champion` (el **benchmark**): calidad de los datos
(*Data Quality*) y cambios de comportamiento (*Data Drift*). Guarda las métricas en PostgreSQL y las muestra en Grafana,
con alertas. **No cambia el modelo ni los scores.**

Diseño: [`doc/monitorization_arch.md`](doc/monitorization_arch.md) · CI/CD: [`doc/ci_cd.md`](doc/ci_cd.md)

# Setup del sistema

La guía va del Paso 0 al 7, en orden. Los pasos 1 al 4 preparan todo y se hacen **una sola vez**, con los scripts de
[`setup/`](setup/). El 5 se repite con cada champion nuevo y el 7 con cada lote.

| Paso | Qué se logra | Cómo | Dónde actúa |
|---|---|---|---|
| [0](#paso-0--completar-el-setup-de-entrenamiento) | Todo lo compartido y un `@champion` | guía de entrenamiento | — |
| [1](#paso-1--comprobar-los-requisitos) | Saber que no falta nada | `paso1.sh` | solo lee |
| [2](#paso-2--configurar-el-correo-de-alertas) | Correo de alertas y bucket de datos | `paso2.sh` | tu máquina |
| [3](#paso-3--levantar-el-monitoreo) | Servidor, base de datos y Grafana | `paso3.sh` | AWS 💰 |
| [4](#paso-4--conectar-github-con-el-monitoreo) | GitHub sabe a qué AWS conectarse | `paso4.sh` | GitHub |
| [5](#paso-5--construir-el-benchmark) | Referencia del champion | GitHub Actions | AWS 💰 |
| [6](#paso-6--crear-un-lote-de-prueba-opcional) | Un lote para probar, si no tienes datos nuevos | `paso6.sh` | AWS |
| [7](#paso-7--correr-el-monitoreo) | Métricas y alertas de un lote | GitHub Actions | AWS 💰 |

💰 = cobra mientras la EC2 está encendida.

**Cómo se comportan los scripts:** igual que los de entrenamiento. Revisan, muestran qué falta, preguntan `[y/n]` y
comprueban el resultado. Sin una `y` no cambian nada, repetirlos es seguro y no piden credenciales.

Los comandos se corren **desde la raíz del repo**. En los ejemplos tu repo es `ana/vantix`. Si tu perfil de AWS no se
llama `vantix`, agrega `--profile=NOMBRE`.

### Paso 0 · Completar el setup de entrenamiento

**Por qué:** el monitoreo compara contra los datos del champion y reutiliza las herramientas, sesiones e infraestructura.

Completa los pasos 0 al 13 de [`pipelines/training/README.md`](../pipelines/training/README.md).

### Paso 1 · Comprobar los requisitos

**Por qué:** el monitoreo da por hecho cosas de tu cuenta que es mejor comprobar antes de crear nada.

```bash
bash monitorization/setup/paso1.sh
```

**Qué hace:** solo lee. Comprueba GitHub, AWS, el champion y los datos, y lo que está **fijo** en el código: la VPC por
defecto, su subred en `us-east-1a` y la imagen base del servidor (AMI). Si algo falta, dice cómo resolverlo.

### Paso 2 · Configurar el correo de alertas

**Por qué:** Grafana avisa por correo cuando hay alertas. No es una credencial, pero es un dato personal: se guarda en
`monitorization/infra/terraform.tfvars`, que no se sube a git.

```bash
bash monitorization/setup/paso2.sh --alert-email=ana@ejemplo.com
```

**Qué hace:** guarda el correo y el bucket de datos, que lee de la infraestructura. Conserva lo demás del archivo.

### Paso 3 · Levantar el monitoreo

**Por qué:** crea dónde se calculan, guardan y ven las métricas. Corre en su propio servidor para no depender de
SageMaker ni afectar a los otros sistemas.

```bash
bash monitorization/setup/paso3.sh
```

**Qué hace:** la primera vez construye la imagen del backend, la sube a ECR y crea la infraestructura. Después solo
actualiza la infraestructura: la imagen la publica el CI. Exige que `monitorization/` esté **commiteado**, porque la
imagen se etiqueta con su commit.

| Recurso | Para qué |
|---|---|
| EC2 + disco EBS de datos | PostgreSQL, Grafana y el job. El disco sobrevive si la EC2 se reemplaza |
| CloudFront | Grafana por HTTPS; el servidor no se expone directamente |
| Bucket `vantix-monitoring-<cuenta>` | benchmark y respaldos de la base |
| ECR y puntero en SSM | imágenes del backend y cuál está vigente |
| SES | envío de los correos de alerta |
| Roles `vantix-monitoring-github-ci` y `-run` | uno publica la imagen; el otro solo enciende la EC2 y ejecuta el job |

- **Confirma el correo:** AWS te envía un mensaje de verificación que vence a las 24 horas. Sin confirmarlo todo funciona,
  pero no llegan correos. Si venció, el script muestra cómo pedir otro.
- **Un cambio puede reemplazar la EC2:** el script lo avisa antes. Si el plan borrara los datos, se detiene.
- 💰 La EC2 queda **encendida**: apágala con `cd monitorization && make stop`.

### Paso 4 · Conectar GitHub con el monitoreo

**Por qué:** los workflows necesitan saber qué roles usar y dónde está Grafana: 3 variables, que no son secretos. Van a
nivel de repo y no en `production`, porque estos workflows **no piden aprobación**: no tocan el modelo ni los scores.

```bash
bash monitorization/setup/paso4.sh
```

**Qué hace:** lee los valores de la infraestructura, los guarda en GitHub y comprueba que AWS confía en la rama `main` de
tu repo.

### Paso 5 · Construir el benchmark

**Por qué:** es la referencia contra la que se compara todo. Debe hacerse con los **mismos datos** que entrenaron al
champion, y repetirse cada vez que se promueve otro.

**Actions** → **run_monitoring_manual** → **Run workflow** (rama `main`):

| Campo | Qué poner con el dataset de la guía |
|---|---|
| `job` | `build_benchmark` |
| `ingest_date` | `2025-04-30` (el lote con el que se entrenó) |
| `snapshot_date` | `auto` (aquí no se usa) |
| `stop_after` | sin marcar |

El workflow enciende la EC2 solo. Desde la terminal:

```bash
gh workflow run run_monitoring_manual.yml -R ana/vantix --ref main -f job=build_benchmark -f ingest_date=2025-04-30
```

### Paso 6 · Crear un lote de prueba (opcional)

**Por qué:** el monitoreo necesita un lote distinto del benchmark. Si aún no tienes datos nuevos, puedes generar uno.

```bash
bash monitorization/setup/paso6.sh --tipo=estable       # lote 2025-06-30
bash monitorization/setup/paso6.sh --tipo=degradado     # lote 2025-07-31
```

| Tipo | Qué tiene | Resultado esperado |
|---|---|---|
| `estable` | el mismo comportamiento, en otras fechas | 0 alertas |
| `degradado` | nulos, duplicados, días sin datos, montos y cuotas alterados | 10 alertas |

🚨 **Queda junto a los datos reales y no se puede sobrescribir.** Si es el más reciente, pasa a ser "el último": la
inferencia y el monitoreo lo usarían con fechas `auto`. Por eso esta guía usa siempre fechas explícitas.

### Paso 7 · Correr el monitoreo

**Por qué a mano:** lo lanza el especialista cuando llega un lote, y él decide qué hacer con el resultado. Reentrenar
nunca es automático.

**Actions** → **run_monitoring_manual** → **Run workflow** (rama `main`):

| Campo | Qué es | Ejemplo (lote estable) |
|---|---|---|
| `job` | qué se ejecuta | `run_monitoring` |
| `ingest_date` | lote que se revisa | `2025-06-30` |
| `snapshot_date` | día de corte: el anterior al lote | `2025-06-29` |
| `stop_after` | apagar la EC2 al terminar | sin marcar, si quieres ver Grafana |

```bash
gh workflow run run_monitoring_manual.yml -R ana/vantix --ref main -f job=run_monitoring \
  -f ingest_date=2025-06-30 -f snapshot_date=2025-06-29
```

1. El **Summary** de la corrida muestra el resultado y el enlace al dashboard.
2. Entra a Grafana: usuario `admin`, contraseña con `cd monitorization && make password`.
3. Para decidir qué hacer con una alerta: [guía de evaluación](doc/monitorization_arch.md#6-guía-de-evaluación-para-el-especialista-next-steps).
4. 💰 Apaga la EC2: `cd monitorization && make stop`.

| Si ves esto… | Casi siempre es… |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | AWS no confía en tu repo ([Paso 4 de entrenamiento](../pipelines/training/README.md#paso-4--autorizar-tu-repo-en-aws-oidc) y después el [Paso 3](#paso-3--levantar-el-monitoreo)), o no se lanzó desde `main` |
| `Could not load credentials` o un valor vacío | faltan variables: [Paso 4](#paso-4--conectar-github-con-el-monitoreo) |
| `No existe la EC2` | el servidor no está creado: [Paso 3](#paso-3--levantar-el-monitoreo) |
| `No hay benchmark para el champion` | falta el [Paso 5](#paso-5--construir-el-benchmark), o se promovió otro champion |
| No llegan correos | el correo no está confirmado: [Paso 3](#paso-3--levantar-el-monitoreo) |
