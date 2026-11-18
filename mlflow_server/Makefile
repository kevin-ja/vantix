# MLflow tracking server desechable en AWS. Todos los comandos de operación viven aquí.
#
#   make venv           entorno local (Python fijo + deps con hash) para tests y lock
#   make lock           regenera los locks de Python (docker/ y tests/) desde los .in
#   make up             crea/actualiza todo: ECR → imagen → infra (la EC2 se reemplaza si cambia la imagen/config)
#   make image          construye (linux/amd64) y sube la imagen con tag = commit de mlflow_server/
#   make plan           terraform plan
#   make start | stop | status    encender / apagar / ver la EC2 (el estado vive en S3)
#   make url | password           URL del servidor / contraseña de admin (usuario: admin)
#   make smoke          test de humo contra el servidor
#   make recreate-test  prueba de resiliencia: escribe → DESTRUYE la EC2 → recrea → verifica que todo sigue
#   make logs | shell   logs de los contenedores / consola en la EC2 (SSM, sin SSH)
#   make down           destruye el cómputo (EC2, IP, CloudFront); conserva bucket, imagen y contraseña
#   make destroy-all CONFIRM=yes   destruye TODO, incluido el bucket con el estado
#
# Variables: STATE_BUCKET (estado de Terraform, obligatorio), AWS_PROFILE, REGION, NAME.

AWS_PROFILE  ?=
REGION       ?= us-east-1
NAME         ?= mlflow-server
STATE_BUCKET ?=
STATE_KEY    ?= mlflow-server/terraform.tfstate
PYTHON_VERSION := 3.11.18

TF       := terraform -chdir=infra
VENV_PY  := .venv/bin/python
# Tag inmutable: último commit que tocó mlflow_server/ (cambia solo si cambia el servidor).
IMAGE_TAG = $(shell git log -1 --format=%h -- .)
AWS       = aws $(if $(AWS_PROFILE),--profile $(AWS_PROFILE)) --region $(REGION)
TF_VARS   = -var=name=$(NAME) -var=region=$(REGION) -var=image_tag=$(IMAGE_TAG) \
            $(if $(AWS_PROFILE),-var=aws_profile=$(AWS_PROFILE))
out       = $(shell $(TF) output -raw $(1))

.PHONY: help venv lock check-clean init up image plan start stop status url password smoke recreate-test \
        logs shell down destroy-all

help:
	@sed -n '3,16p' Makefile | sed 's/^# \{0,1\}//'

# --- entorno local y locks ----------------------------------------------------------------
venv:
	uv venv --python $(PYTHON_VERSION) .venv
	uv pip install --python $(VENV_PY) --require-hashes -r tests/requirements.txt

lock:
	uv pip compile docker/requirements.in -o docker/requirements.txt --generate-hashes --no-header \
		--python-version 3.10 --python-platform x86_64-manylinux_2_28
	uv pip compile tests/requirements.in -o tests/requirements.txt --generate-hashes --no-header \
		--python-version 3.11 --universal

# --- infra --------------------------------------------------------------------------------
# La imagen se etiqueta con un commit: el código tiene que estar commiteado.
check-clean:
	@test -n "$(STATE_BUCKET)" || { echo "Falta STATE_BUCKET (bucket del estado de Terraform)"; exit 1; }
	@test -z "$$(git status --porcelain -- .)" || { echo "mlflow_server/ tiene cambios sin commitear"; exit 1; }

init: check-clean
	$(TF) init -input=false -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" -backend-config="key=$(STATE_KEY)" \
		-backend-config="region=$(REGION)" -backend-config="use_lockfile=true" \
		$(if $(AWS_PROFILE),-backend-config="profile=$(AWS_PROFILE)")

up: init
	$(TF) apply -input=false -auto-approve $(TF_VARS) -target=aws_ecr_repository.mlflow
	$(MAKE) image
	$(TF) apply -input=false $(TF_VARS)
	@echo "Servidor: $(call out,tracking_uri)  (arranca en ~2-3 min; make status)"

image:
	@repo=$(call out,ecr_repository_url); \
	if $(AWS) ecr describe-images --repository-name $(NAME) --image-ids imageTag=$(IMAGE_TAG) >/dev/null 2>&1; then \
		echo "Imagen $$repo:$(IMAGE_TAG) ya existe (tags inmutables)"; exit 0; fi; \
	$(AWS) ecr get-login-password | docker login --username AWS --password-stdin $${repo%%/*} && \
	docker buildx build --platform linux/amd64 --provenance=false -t $$repo:$(IMAGE_TAG) --push docker

plan: init
	$(TF) plan -input=false $(TF_VARS)

# --- operación ----------------------------------------------------------------------------
start:
	$(AWS) ec2 start-instances --instance-ids $(call out,instance_id) --query 'StartingInstances[0].CurrentState.Name' --output text
	$(AWS) ec2 wait instance-running --instance-ids $(call out,instance_id)
	@echo "EC2 encendida; MLflow listo en ~1 min: make status"

stop:
	$(AWS) ec2 stop-instances --instance-ids $(call out,instance_id) --query 'StoppingInstances[0].CurrentState.Name' --output text

status:
	@echo "EC2:    $$($(AWS) ec2 describe-instances --instance-ids $(call out,instance_id) --query 'Reservations[0].Instances[0].State.Name' --output text)"
	@echo "MLflow: $$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 $(call out,tracking_uri)/health) (200 = arriba)"
	@echo "URL:    $(call out,tracking_uri)"

url:
	@echo $(call out,tracking_uri)

password:
	@$(AWS) ssm get-parameter --name $(call out,admin_password_parameter) --with-decryption --query Parameter.Value --output text

# --- pruebas ------------------------------------------------------------------------------
SMOKE_ENV = MLFLOW_TRACKING_URI=$(call out,tracking_uri) MLFLOW_TRACKING_USERNAME=admin \
            MLFLOW_TRACKING_PASSWORD=$$($(AWS) ssm get-parameter --name $(call out,admin_password_parameter) \
              --with-decryption --query Parameter.Value --output text)

smoke:
	$(SMOKE_ENV) $(VENV_PY) -m pytest -q tests/test_smoke.py -k "not persisted"

# Escribe, destruye la EC2 (y su disco), la recrea y comprueba que el estado volvió desde S3.
recreate-test: init smoke
	@echo "Esperando a que Litestream replique a S3..."; sleep 15
	$(TF) apply -input=false -auto-approve $(TF_VARS) -replace=aws_instance.mlflow
	@echo "Esperando a la EC2 nueva..."; \
	for i in $$(seq 1 60); do \
		[ "$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 $(call out,tracking_uri)/health)" = 200 ] && break; \
		sleep 10; done
	$(SMOKE_ENV) $(VENV_PY) -m pytest -q tests/test_smoke.py -k persisted

logs:
	@id=$$($(AWS) ssm send-command --instance-ids $(call out,instance_id) --document-name AWS-RunShellScript \
		--parameters 'commands=["cd /opt/mlflow && docker compose ps -a && docker compose logs --tail 60"]' \
		--query Command.CommandId --output text); \
	$(AWS) ssm wait command-executed --command-id $$id --instance-id $(call out,instance_id) || true; \
	$(AWS) ssm get-command-invocation --command-id $$id --instance-id $(call out,instance_id) \
		--query StandardOutputContent --output text

shell:
	$(AWS) ssm start-session --target $(call out,instance_id)

# --- bajar --------------------------------------------------------------------------------
down: init
	$(TF) destroy -input=false $(TF_VARS) -target=aws_cloudfront_distribution.mlflow \
		-target=aws_eip_association.mlflow -target=aws_instance.mlflow -target=aws_eip.mlflow

destroy-all: init
	@test "$(CONFIRM)" = "yes" || { echo "Borra el bucket con el estado de MLflow. Repite con CONFIRM=yes"; exit 1; }
	$(TF) destroy -input=false $(TF_VARS)
