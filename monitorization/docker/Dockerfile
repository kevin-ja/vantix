# Imagen del backend del monitoreo (jobs build_benchmark / run_monitoring / restore).
# Contexto del build = raíz del repo, para reutilizar SOLO lo compartido de pipelines/common sin copiarlo
# al repo (ver Dockerfile.dockerignore: lista blanca de archivos). Build:
#   docker buildx build --platform linux/amd64 -f monitorization/docker/Dockerfile .
#
# Debian trixie trae postgresql-client 17: la misma versión mayor que el servidor (compose.yml). Si no coinciden,
# un dump de pg_dump 17 no se puede restaurar en un servidor 16 (SET transaction_timeout).
FROM python:3.11-slim-trixie@sha256:07d4824036af339fa1b6ef769cc99d9c10a141769538b52b3b597c84f7a7b535

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY monitorization/docker/requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt

# Código compartido con entrenamiento/inferencia: solo los módulos que el monitoreo usa.
COPY pipelines/__init__.py                pipelines/__init__.py
COPY pipelines/common/__init__.py         pipelines/common/__init__.py
COPY pipelines/common/config.py           pipelines/common/config.py
COPY pipelines/common/features.py         pipelines/common/features.py
COPY pipelines/common/io.py               pipelines/common/io.py
COPY pipelines/common/storage.py          pipelines/common/storage.py
COPY monitorization/src/monitoring        monitoring

ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT} PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER nobody
ENTRYPOINT ["python", "-m", "monitoring"]
