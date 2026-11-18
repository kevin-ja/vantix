# VANTIX · Reporte de la prueba end to end en AWS (2026-11-18)

## Resumen

Los dos sistemas, entrenamiento e inferencia, **funcionan en producción en SageMaker** de punta a punta. Ambos pasaron al primer intento después de dos arreglos menores. Costo total: **unos USD 0,60**. Resultado: 15.000 clientes nuevos clasificados en 5 segmentos.

## Qué se hizo

1. **Validación previa en local:** 21 de 21 tests pasan, más una corrida completa en local.
2. **Infraestructura con Terraform:** S3, MLflow administrado, roles IAM y el scheduler semanal de inferencia, que quedó **apagado**.
3. **Entrenamiento en SageMaker:** con los datos reales (842.163 apuestas, 108.008 usuarios), probando de 2 a 10 grupos (k). Las métricas salieron **idénticas a las de la corrida local**, así que el resultado es reproducible.
4. **Elección de k=5:** tiene la mejor separación entre grupos (Davies-Bouldin 1,10, el más bajo) con una cohesión casi igual a la de k=2–4 (silhouette 0,31).
5. **Nombres de los grupos** (`segment_map.json`) y **promoción** del modelo como `@champion` v1 en MLflow. El paquete del modelo quedó exportado a `s3://…/models/champion/`.
6. **Inferencia en SageMaker** sobre un **lote sintético**: 15.000 usuarios **nuevos** y 94.307 apuestas de mayo de 2025, generadas a partir del comportamiento real de abril con cambios en montos, fechas y cantidad de apuestas (`scripts/make_synthetic_batch.py`). Ningún usuario ni transacción coincide con los de entrenamiento. La salida de AWS es **idéntica a la de la corrida local para los 15.000 clientes**.
7. **MLflow apagado** al terminar. No quedó nada corriendo.

## Los segmentos

| Segmento | Usuarios (entrenamiento) | % del profit | Usuarios (lote nuevo) | Quiénes son |
|---|---|---|---|---|
| VIP activo | 18 % | 59 % | 15 % | Juegan casi a diario y mueven mucho dinero. |
| Habitual en enfriamiento | 25 % | 25 % | 22 % | Buenos clientes que llevan unas 2 semanas sin jugar. |
| Reciente ocasional | 15 % | 7 % | 16 % | Jugaron hace poco, pero poco y con montos bajos. |
| Inactivo de bajo valor | 31 % | 8 % | 35 % | Una apuesta hace unas 3 semanas, y nada más. |
| Cazador de cuotas altas | 11 % | 2 % | 11 % | Pocas apuestas, a cuotas muy altas. |

## Tiempos

**Infraestructura (Terraform)**, del recurso más lento al más rápido:

| Recurso | Tiempo |
|---|---|
| Servidor de MLflow (SageMaker) | **20 min 46 s**: el 98 % de todo el levantamiento |
| Buckets S3 (datos, scores, estado) y su configuración | 1–3 s cada uno |
| Roles y políticas IAM | 0–2 s cada uno |
| Scheduler de EventBridge | < 1 s |
| Redes (VPC, NAT) y ECR | No aplica: no se usan |
| **Total** | `up-training` 21 min 16 s · `up-inference` 29 s |

**Sin MLflow, todo queda listo en ~1,5 min**:

| Qué | Tiempo |
|---|---|
| Infra de training sin MLflow (S3 + IAM) | ~30 s |
| Infra de inferencia (S3 + IAM + scheduler) | 29 s |
| Crear o actualizar el pipeline de training en SageMaker (SDK) | 14 s |
| Crear o actualizar el pipeline de inferencia en SageMaker (SDK) | 13 s |

Terraform no crea recursos de SageMaker salvo MLflow: los pipelines los crea el SDK, y las máquinas se encienden en cada job (ver la tabla siguiente).

**Pipelines (SageMaker)**:

| Paso | Total | Arrancar la máquina | Descargar la imagen | Instalar librerías | **Cómputo real** | Cierre y subida a S3 |
|---|---|---|---|---|---|---|
| Prepare | 5 min 03 s | 1 min 05 s | 1 min 36 s | 36 s | **8 s** | 1 min 23 s |
| Train | 27 min 36 s | 43 s | 1 min 09 s | 34 s | **22 min 42 s** (~2,5 min por k) | 2 min 27 s |
| Score (inferencia) | 2 min 33 s | 44 s | 1 min 09 s | — | **6 s** | 32 s |

Otros pasos: subir los datos a S3 tardó 8 s y la promoción, 50 s.

## Dónde se puede optimizar el tiempo

1. **MLflow (21 min).** Un MLflow propio en una máquina chica se levantaría en 2–3 minutos y costaría mucho menos. Ya era el próximo paso planeado.
2. **Train (23 min de cómputo).** Casi todo el tiempo se va en calcular la métrica silhouette con el 100 % de los datos. Opciones:
   - usar una máquina más rápida (`ml.m5` o `ml.c5`, cuando AWS apruebe la cuota);
   - probar menos valores de k (por ejemplo, de 3 a 7);
   - calcular la silhouette con una muestra (hoy se decidió no hacerlo).
3. **Arranque fijo de unos 3 minutos por job** (máquina, imagen y librerías), mientras que el cómputo de Prepare y Score dura segundos. Unir Prepare y Train en un solo job ahorraría unos 4 minutos.

## Ajustes hechos durante la prueba

- **Train corre como Processing job** (`ml.t3.xlarge`), porque la cuota de training sigue en 0. Es el mismo código y da el mismo resultado. Se puede volver a Training job cuando AWS apruebe la cuota.
- **Arreglo en el scheduler de inferencia:** AWS exige que el target tenga al menos un parámetro, así que se le pasan las fechas en `auto`. Es lo mismo que el pipeline ya usa por defecto.
- **La cuenta AWS estaba bloqueada** por una deuda de USD 1 en la cuenta de gestión. Se resolvió al pagarla.

## Costo aproximado

MLflow encendido unos 57 min, creación incluida: ~USD 0,55. Máquinas de SageMaker, unos 30 min en total: ~USD 0,10. S3: centavos al mes.

## Pendiente

- Hacer commit de los cambios: `pipeline_sagemaker.py`, `infra/inference/main.tf`, `segment_map.json` y el script del lote sintético. Los jobs registraron el código como `3e7cb50-dirty`.
- Montar el MLflow propio, encender el scheduler semanal (`make schedule-on`) y definir el CI/CD.
