# mlflow_server

Servidor de tracking de MLflow propio en AWS: **desechable, con el estado en S3** (Litestream) y HTTPS vía CloudFront.
Arquitectura, alcance y limitaciones: [`docs/architecture.md`](docs/architecture.md).

## Estructura

```
docker/        Dockerfile + requirements.in/.txt (lock con hashes) + basic_auth.ini
compose.yml    restore (Litestream) → mlflow → replicate (Litestream)
litestream.yml réplica continua de las bases SQLite a S3
infra/         Terraform: S3, ECR, EC2, Elastic IP, CloudFront, IAM, SSM (+ user_data de la EC2)
tests/         test de humo y de persistencia
Makefile       todos los comandos
```

## Requisitos

AWS CLI con un perfil, Terraform 1.15.8, Docker con `buildx`, `uv`, `session-manager-plugin` y un bucket para el
estado de Terraform.

## Uso

```bash
make venv                                  # una vez: Python 3.11.18 + deps de los tests (con hashes)
make up STATE_BUCKET=<bucket-estado>       # crea todo; con cambios commiteados, actualiza (reemplaza la EC2)
make status | url | password               # estado, URL y contraseña de admin
make smoke                                 # test de humo
make recreate-test                         # resiliencia: destruye la EC2 y verifica que el estado vuelve de S3
make stop | start                          # apagar / encender (el estado vive en S3)
make down                                  # quita el cómputo; conserva bucket, imagen y contraseña
```

Autocontenido: no depende del repo que lo aloja. Variables: `STATE_BUCKET` (obligatoria), `AWS_PROFILE`, `REGION`, `NAME`
(prefijo de los recursos, por defecto `mlflow-server`).

Clientes:

```bash
export MLFLOW_TRACKING_URI=$(make -s url) MLFLOW_TRACKING_USERNAME=admin MLFLOW_TRACKING_PASSWORD=$(make -s password)
```
