# VANTIX · Arquitectura MLOps (CI/CD para ML)

> Documento vivo. Se completa por secciones, en orden. Base: [`training_pipeline_arch.md`](training_pipeline_arch.md) · [`inference_pipeline_arch.md`](inference_pipeline_arch.md).

## 1. Principio: coherencia del pipeline de entrenamiento

- Los artefactos del modelo (`preprocessor.pkl`, `model.pkl`, `segment_map.json`) **nunca cambian solos**. Siempre los antecede un cambio en los **datos** o en el **código de entrenamiento**.
- Los tres artefactos salen del mismo run y se publican juntos. No se actualiza uno sin los demás.

## 2. Fuentes de cambio y su impacto

| # | Fuente | Qué dispara | Impacto | Modo |
|---|---|---|---|---|
| 1 | **Datos nuevos** (lote en `raw/`) | Inferencia, siempre. Reentrenamiento, solo según la política (§2.1). | Entrenamiento → nuevo modelo → inferencia | Inferencia: automática. Reentrenamiento: por política. |
| 2 | **Código de entrenamiento** (`pipelines/training/`, rango de k, ventana) | CI → actualizar el pipeline → reentrenar | Igual que la fuente 1 | Automático hasta el entrenamiento; promoción manual |
| 3 | **Código de inferencia** (`pipelines/inference/`) | CI → actualizar el pipeline de inferencia | Solo inferencia | Automático |
| 4 | **Código común** (`pipelines/common/`: validación, features, preprocesador) | CI → **ambos** pipelines | Reentrenar **y** volver a desplegar la inferencia juntos, para evitar *training-serving skew* | Automático hasta el entrenamiento; promoción manual |
| 5 | **Entorno y dependencias** (contenedor 1.4-2, `requirements.txt`) | CI → ambos pipelines | Si cambia scikit-learn, los `.pkl` dejan de ser compatibles → reentrenar | Igual que la fuente 4 |
| 6 | **Infraestructura** (`infra/`, Terraform) | `plan` en la revisión → `apply` | Recursos de AWS (no el modelo) | Manual con aprobación |
| 7 | **Decisión humana**: promover, renombrar segmentos, rollback | Exportar `@champion` | Solo inferencia: cambia el modelo servido sin reentrenar | Manual |

### 2.1 Datos nuevos ≠ reentrenar siempre

- Cada lote semanal se **puntúa** con el champion vigente.
- Reentrenar en cada lote cambiaría los segmentos cada semana y rompería la continuidad de las campañas.
- El reentrenamiento se dispara por: calendario (por ejemplo, mensual), deriva detectada en la distribución de segmentos o features, o una decisión de negocio.

## 3. Criterios por sistema

### 3.1 Entrenamiento

1. Versionar los datos de entrenamiento.
2. Versionar el código de entrenamiento.
3. Registrar los experimentos y sus artefactos.
4. Versionar los artefactos del modelo (Model Registry).
5. Validar los datos antes de entrenar.
6. Que los resultados sean reproducibles (mismos datos + código + semilla → mismo modelo).
7. Promoción **manual** por un especialista, a partir de métricas y de su experiencia, comparando contra un benchmark fijo (§5).
8. Los nombres de los segmentos (`segment_map`) los define el especialista en cada promoción, de forma sencilla y versionada (§5).

### 3.2 Inferencia

1. Versionar el código de inferencia.
2. Rollback del modelo servido.
3. Rollback del código de inferencia.
4. Trazabilidad de cada salida: modelo, código y datos.
5. Monitorear la ejecución (fallos) y la distribución de segmentos (deriva).

### 3.3 Transversal

1. Repositorio remoto y flujo por PR (CI en cada PR, CD al hacer merge).
2. Autenticación de CI/CD con AWS sin llaves fijas (OIDC).
3. Infraestructura solo por Terraform, con `plan` revisado.

## 4. Estado actual (2026-11-18)

| Criterio | Estado | Cómo está hoy / qué falta |
|---|---|---|
| Versionar datos | ✅ | Rutas inmutables en `raw/` (`upload_raw` no sobrescribe), S3 Versioning y SHA-256 del crudo y de las features en MLflow |
| Versionar código de entrenamiento | 🟡 | Git local (sin remoto); `git_commit` en cada run, marcado `-dirty` si hay cambios |
| Registrar experimentos y artefactos | ✅ | MLflow: run padre por corrida, run hijo por k, métricas, perfiles y `.pkl` |
| Versionar artefactos | ✅ | Model Registry `vantix-segmentation`, alias `@champion`, tags `k` y `snapshot_date` |
| Validar datos | ✅ | `validate.py` en cada corrida (entrenamiento e inferencia) |
| Reproducibilidad | ✅ | Semilla fija; mismas métricas en local y en AWS. 🟡 Algunas dependencias van por rango (`mlflow>=2.16,<4`) |
| Promoción manual simple + benchmark | 🟡 | Decidido (§5): manual por diseño. Falta congelar el benchmark, el workflow `promote.yml` y los tags |
| Nombres de segmentos | 🟡 | Decidido (§5): el especialista los define en cada promoción, por PR en `segment_maps/` |
| Versionar código de inferencia | ✅ | `git_commit` fijado en el upsert del pipeline → `GIT_COMMIT` → `summary.json` (`inference_git_commit`) |
| Rollback del modelo | ✅ | Reasignar `@champion` + `make promote-export`. S3 Versioning en `models/champion/`. Requiere MLflow encendido |
| Rollback del código de inferencia | ❌ | El upsert sobrescribe el pipeline; hoy solo se puede volver a ejecutar a mano un commit anterior |
| Trazabilidad de la salida | ✅ | `summary.json`: datos (`raw_sha256`), modelo (`model_version`, `run_id`), `training_git_commit` e `inference_git_commit` |
| Monitoreo | ❌ | Sin alarmas por fallo del pipeline ni chequeo de deriva |
| Tests | 🟡 | 21 tests unitarios y de integración local; sin lint ni chequeos de Terraform automatizados |
| Repositorio remoto + CI/CD | ❌ | Sin remoto ni `.github/workflows/` |
| OIDC con AWS | ❌ | Solo SSO de la persona |
| Disparo por datos nuevos | ❌ | Carga y corridas manuales; el scheduler semanal existe pero está apagado |
| Ambientes (staging/prod) | ❌ | Una sola cuenta. Pendiente de decidir |

## 5. Promoción, benchmark y rollback (decidido)

La promoción **es manual por diseño**. El especialista decide con métricas y con su experiencia: elige k, analiza los clusters y los nombra. Lo que se automatiza es que hacerlo sea simple: sin código nuevo en cada promoción, solo parámetros.

### 5.1 Benchmark (una sola vez)

- El primer champion (v1, k=5, `snapshot_date=2025-04-30`) se copia de `s3://…/models/champion/` a `s3://…/models/benchmark/`, junto con `cluster_profile_k5.csv` y `k_summary.csv` de su run.
- En el Model Registry, la v1 lleva además el alias `@benchmark`.
- Una política del bucket bloquea las escrituras en `models/benchmark/*` (Terraform), para que no se pise.

### 5.2 Evaluación (especialista, sin código)

- En MLflow revisa las métricas por k y el perfil de los clusters del run nuevo, y los compara con `models/benchmark/`.
- Elige el k y escribe el `segment_map` del run elegido.

### 5.3 Promoción

- **Segment map:** el especialista lo sube por PR a `segment_maps/<snapshot_date>_k<k>.json`. Queda versionado, revisado y con historial de nombres.
- **Workflow `promote.yml`** (GitHub Actions, `workflow_dispatch`), con tres parámetros:
  - `run_id`: el run hijo elegido;
  - `segment_map`: la ruta del archivo en el repo;
  - `reason`: la justificación, en texto libre.
- **Qué hace:** corre el `promote.py` existente (registra la versión, asigna `@champion` y exporta a `models/champion/`) y etiqueta la versión con `promoted_by` (el usuario de GitHub), `reason` y `segment_map`.
- **Aprobación:** un *environment* `production` de GitHub con aprobador obligatorio.

### 5.4 Rollback

- Es el mismo workflow, con un parámetro `version`: reasigna `@champion` a esa versión del registry y la vuelve a exportar a `models/champion/`.

### 5.5 Dependencia

- Promover y hacer rollback requieren MLflow encendido. Con el MLflow administrado, el workflow debe encenderlo y apagarlo (tarda varios minutos). Con el MLflow propio (pendiente), queda trivial.
