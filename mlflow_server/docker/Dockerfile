# Imagen del tracking server de MLflow (con basic auth). El estado NO vive en la imagen ni en el contenedor:
# las bases SQLite están en /data y Litestream las replica a S3 (ver ../compose.yml y ../docs/architecture.md).
# Reproducible: base fijada por digest y dependencias instaladas desde un lock con hashes (--require-hashes).
FROM python:3.10.19-slim-bookworm@sha256:23f63358922e79a794f71be8f3723c84e5ccca9638af3f74456dc73d6184499e

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MLFLOW_AUTH_CONFIG_PATH=/etc/mlflow/basic_auth.ini

COPY requirements.txt /tmp/requirements.txt
RUN pip install --require-hashes --no-deps -r /tmp/requirements.txt && rm /tmp/requirements.txt

COPY basic_auth.ini /etc/mlflow/basic_auth.ini

VOLUME ["/data"]
EXPOSE 5000

# El comando del servidor se define en compose.yml (depende del bucket y del host público).
ENTRYPOINT ["mlflow"]
CMD ["server", "--help"]
