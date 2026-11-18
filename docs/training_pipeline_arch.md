# VANTIX · Arquitectura del pipeline de entrenamiento

Segmentación de clientes con KMeans sobre 5 features por usuario: Recency, Frequency, Monetary, Profit_30d y Avg_Odds.

## 1. Tech stack

| Capa | Tecnología |
|---|---|
| Almacenamiento | S3 con versioning activado |
| Datos | pandas + Parquet |
| Orquestación y cómputo | SageMaker Pipelines (Processing y Training jobs) |
| Modelo | scikit-learn: `preprocessor` (Yeo-Johnson → Winsorizer → MinMaxScaler) y `model` (KMeans) |
| Tracking y versionado | MLflow administrado por SageMaker |

## 2. Diagrama general

```
 S3                       SageMaker Pipelines                                MLflow (SageMaker)
 ──                       ───────────────────                                ──────────────────
 raw/ingest_date=…/       ┌─ Processing job ─────────────────┐
 data.parquet ──────────▶ │ 1 Ingesta                        │
                          │ 2 Validación  (falla → se corta) │
                          │ 3 Limpieza                       │
                          │ 4 Features                       │──▶ silver/user_features/
                          └──────────────────────────────────┘    snapshot_date=…/  (S3)
                                          │
                          ┌─ Training job ▼──────────────────┐
                          │ 5 Preprocesamiento (fit)         │
                          │ 6 KMeans para cada k             │──▶ run padre + run hijo por k
                          │ 7 Evaluación (100 % de los datos)│    (métricas, perfil, .pkl)
                          └──────────────────────────────────┘
                                                                              │
                                     8 Revisión y promoción manual  ◀─────────┘
                                                    │
                                                    ▼
                                     Model Registry: vantix-segmentation@champion
                                     (artefactos en S3) ──▶ pipeline de inferencia
```

## 3. Pasos

1. **Ingesta.** Lee `raw/ingest_date=YYYY-MM-DD/data.parquet` desde S3 (la versión en Parquet de `data.csv`).
2. **Validación.** `validate(df)` revisa:
   - esquema y tipos;
   - nulos en columnas críticas;
   - `TransId` repetidos con contenido distinto;
   - BetType conocido;
   - Odds ≠ 0 (las cuotas asiáticas pueden ser negativas); Actual_Stake y ActualRate > 0;
   - volumen dentro de ±50 % respecto a la corrida anterior.

   Junta todos los errores y lanza un solo `ValueError`. No es un test: corre en cada ejecución.
3. **Limpieza.** Quita duplicados exactos y columnas que no se usan, y convierte las fechas.
4. **Features.** Agrega por usuario dentro de una ventana de `window_days=30` antes de `snapshot_date`:
   - Recency se calcula contra `snapshot_date`.
   - `LTV_Profit` pasa a llamarse `Profit_30d`, porque es el profit de la ventana y no de la vida del cliente.
   - El resultado se guarda en `silver/user_features/snapshot_date=YYYY-MM-DD/`.
5. **Preprocesamiento.** Se ajusta `preprocessor` con `fit_transform()` y se aprenden las lambdas de Yeo-Johnson, los percentiles p1/p99 y los min/max.
6. **Entrenamiento.** KMeans para cada k del rango. Cada k es un run hijo en MLflow.
7. **Evaluación.** Por cada k se calculan:
   - silhouette, Calinski-Harabasz, Davies-Bouldin e inercia, con el 100 % de las observaciones, sin muestreo;
   - el perfil de clusters: `n`, % de usuarios, media y mediana de las 5 features, % del profit y margen.
8. **Revisión y promoción manual.** Una persona revisa MLflow, elige k, nombra los grupos en `segment_map.json` y asigna el alias `@champion`. Criterios:
   - **Métricas:** silhouette y Calinski-Harabasz más altos, Davies-Bouldin más bajo, codo de la inercia.
   - **Tamaño:** cada cluster con al menos el 2–5 % de los usuarios.
   - **Interpretabilidad:** cada grupo con un perfil claro y una acción comercial posible.
   - **Frente al champion actual:** se reemplaza solo si mejora o si los datos cambiaron.

## 4. Artefactos: entrenamiento vs. inferencia

Los artefactos son **salidas** del entrenamiento. Se guardan tres archivos del mismo run, siempre juntos: `preprocessor.pkl`, `model.pkl` y `segment_map.json`.

```
ENTRENAMIENTO (aprende)
  user_features.parquet
    → preprocessor.fit_transform(X)   # aprende las lambdas de Yeo-Johnson, los percentiles p1/p99 y los min/max
    → kmeans.fit(X_t)                 # aprende los centroides
    → se guardan preprocessor.pkl + model.pkl + segment_map.json  → MLflow / S3

INFERENCIA (solo aplica)
  carga los 3 archivos del champion desde S3/MLflow
    → preprocessor.transform(X_new)   # usa lo aprendido, sin volver a ajustar
    → model.predict(X_t)              # asigna el cluster más cercano
    → segment_map                     # cluster → nombre de segmento
```

> Nota de código: la función `winzor` actual recalcula los percentiles en cada llamada. Hay que convertirla en un transformer de scikit-learn que calcule p1/p99 en `fit()` y los aplique en `transform()`.

## 5. MLflow

- **Experimento:** `vantix-segmentation`.
- **Run padre** (uno por corrida): `snapshot_date`, `window_days`, `git_commit` y hash de los datos.
- **Run hijo** (uno por k): `k`, métricas, perfil de clusters, `preprocessor.pkl` y `model.pkl`. El preprocesador se copia en cada hijo para que cada run esté completo por sí mismo.
- **Model Registry:** el k promovido se registra como una nueva versión de `vantix-segmentation`, con alias `@champion` y `segment_map.json` adjunto.
- **Almacenamiento:** artefactos en S3 y metadatos en una base de datos. La inferencia carga `models:/vantix-segmentation@champion`; no hace falta otro bucket.

## 6. Versionamiento

- **Código:** cada run registra su `git_commit`.
- **Datos (sin DVC):**
  - Rutas inmutables por fecha en S3.
  - S3 Versioning (`VersionId`) como respaldo ante borrados.
  - SHA-256 del Parquet crudo y del de features, registrados como parámetros del run padre (`raw_sha256`, `features_sha256`).
- **Resultado:** cada modelo apunta a su código y a sus datos exactos.

## 7. Decisiones y límites

- **Lógica en `src/`:** se ejecuta igual en local y en la nube. SageMaker es solo una capa delgada de orquestación (`pipeline_sagemaker.py`).
- **Sin Spark:** ~842 mil filas y ~108 mil usuarios caben en memoria. Si los datos crecen, Polars o DuckDB sobre el mismo Parquet.
- **Sin feature store:** las features quedan en Parquet en S3. Solo haría falta si se necesita inferencia en tiempo real.
- **Datos disponibles:** `data.csv` cubre del 2025-03-11 al 2025-04-30. `snapshot_date` se fija a mano en 2025-04-30 (en producción, será la fecha de la corrida). Las transacciones de marzo quedan fuera de la ventana.
- **Limitación aceptada:** Recency va de 0 a ~30 días y los clientes inactivos por más de 30 días no aparecen. Se resuelve ampliando `window_days` cuando haya más historia.
- **Fuera de este pipeline:** el batch scoring va en el pipeline de inferencia.
