# Sistema de monitorización de Vantix. Todos los comandos de operación viven aquí (ver doc/monitorization_arch.md §8).
#
#   make test           tests del backend (usa el .venv de la raíz del repo)
#   make lock           regenera docker/requirements.txt (con hashes) desde requirements.in
#   make up             crea/actualiza la infra (Terraform). El código NO se despliega aquí: lo hace el CI
#                       (ci_monitoring.yml → imagen en ECR + puntero SSM) y el servidor la toma en cada corrida
#   make bootstrap      primera vez en una cuenta nueva: ECR → imagen local → infra (puntero = esa imagen)
#   make image          construye y sube la imagen desde tu máquina (emergencias); NO mueve el puntero
#   make current-image  tag vigente del backend (puntero SSM)
#   make set-image TAG=<tag>   mueve el puntero (rollback a una imagen anterior de ECR)
#   make plan           terraform plan
#   make start | stop | status    encender / apagar (esperan mostrando el estado) / ver la EC2
#   make url | password           URL de Grafana / contraseña de admin
#   make benchmark INGEST_DATE=2025-04-30   job build_benchmark (una vez, y al promover un champion nuevo)
#   make run [INGEST_DATE=…]                job run_monitoring (por defecto: última partición de raw/)
#                       (lo habitual es lanzarlos con run_monitoring_manual.yml desde GitHub, ver doc/ci_cd.md)
#   make logs           logs de db + frontend
#   make down           destruye el cómputo (EC2, IP, CloudFront); conserva bucket, volumen de datos, imagen y secretos
#
# Variables locales (no versionadas): infra/terraform.tfvars con data_bucket y alert_email.

AWS_PROFILE  ?= vantix
REGION       ?= us-east-1
NAME         ?= vantix-monitoring
INGEST_DATE  ?= auto

ROOT         := ..
AWS          = aws --profile $(AWS_PROFILE) --region $(REGION)
ACCOUNT_ID   = $(eval ACCOUNT_ID := $(shell $(AWS) sts get-caller-identity --query Account --output text))$(ACCOUNT_ID)
STATE_BUCKET = vantix-$(ACCOUNT_ID)-tfstate
STATE_KEY    := monitorization/terraform.tfstate
TF           := terraform -chdir=infra
# Tag de la imagen construida en local (make image / bootstrap): último commit que tocó algo que entra en ella.
IMAGE_SOURCES := docker src $(addprefix $(ROOT)/pipelines/,__init__.py common/__init__.py common/config.py \
                 common/features.py common/io.py common/storage.py)
IMAGE_TAG     = $(shell git log -1 --format=%h -- $(IMAGE_SOURCES))
TF_VARS       = -var=name=$(NAME) -var=region=$(REGION) -var=initial_image_tag=$(IMAGE_TAG) -var=aws_profile=$(AWS_PROFILE)
out           = $(shell $(TF) output -raw $(1))

.PHONY: help test lock check-clean init up bootstrap image current-image set-image plan start stop status url \
        password benchmark run logs down

help:
	@sed -n '3,/^[^#]/p' Makefile | grep '^#' | sed 's/^# \{0,1\}//'

test:
	$(ROOT)/.venv/bin/python -m pytest -q tests

lock:
	uv pip compile docker/requirements.in -o docker/requirements.txt --generate-hashes --no-header \
		--python-version 3.11 --python-platform x86_64-manylinux_2_28

# --- infra --------------------------------------------------------------------------------
# La imagen se etiqueta con un commit: el código tiene que estar commiteado.
check-clean:
	@test -z "$$(git status --porcelain -- . $(IMAGE_SOURCES))" || { echo "Hay cambios sin commitear en la imagen o la infra"; exit 1; }

init: check-clean
	$(TF) init -input=false -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" -backend-config="key=$(STATE_KEY)" \
		-backend-config="region=$(REGION)" -backend-config="use_lockfile=true" \
		-backend-config="profile=$(AWS_PROFILE)"

up: init
	$(TF) apply -input=false $(TF_VARS)
	@echo "Grafana: $(call out,grafana_url)  (arranca en ~3 min)."

bootstrap: init
	$(TF) apply -input=false -auto-approve $(TF_VARS) -target=aws_ecr_repository.backend
	$(MAKE) image
	$(TF) apply -input=false $(TF_VARS)
	@echo "Grafana: $(call out,grafana_url)  (arranca en ~3 min). Confirmar el correo de verificación de SES."

image:
	@repo=$(call out,ecr_repository_url); \
	if $(AWS) ecr describe-images --repository-name $(NAME)-backend --image-ids imageTag=$(IMAGE_TAG) >/dev/null 2>&1; then \
		echo "Imagen $$repo:$(IMAGE_TAG) ya existe (tags inmutables)"; exit 0; fi; \
	$(AWS) ecr get-login-password | docker login --username AWS --password-stdin $${repo%%/*} && \
	docker buildx build --platform linux/amd64 --provenance=false --build-arg GIT_COMMIT=$(IMAGE_TAG) \
		-f docker/Dockerfile -t $$repo:$(IMAGE_TAG) --push $(ROOT)

current-image:
	@$(AWS) ssm get-parameter --name $(call out,image_parameter) --query Parameter.Value --output text

set-image:
	@test -n "$(TAG)" || { echo "Falta TAG (tag existente en ECR)"; exit 1; }
	$(AWS) ecr describe-images --repository-name $(NAME)-backend --image-ids imageTag=$(TAG) >/dev/null
	$(AWS) ssm put-parameter --name $(call out,image_parameter) --value $(TAG) --overwrite >/dev/null
	@echo "Puntero → $(TAG) (la próxima corrida usa esa imagen)"

plan: init
	$(TF) plan -input=false $(TF_VARS)

# --- operación ----------------------------------------------------------------------------
# start/stop esperan mostrando el estado en tiempo real (start: hasta que Grafana responde; stop: hasta `stopped`).
start:
	@id=$(call out,instance_id); url=$(call out,grafana_url); \
	$(AWS) ec2 start-instances --instance-ids $$id >/dev/null; \
	while :; do \
		st=$$($(AWS) ec2 describe-instances --instance-ids $$id --query "Reservations[0].Instances[0].State.Name" --output text); \
		code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $$url/api/health); \
		printf '\r%s  EC2 %-10s Grafana %s ' "$$(date +%T)" "$$st" "$$code"; \
		[ "$$code" = 200 ] && break; sleep 5; \
	done; echo; echo "Listo: $$url"

stop:
	@id=$(call out,instance_id); \
	$(AWS) ec2 stop-instances --instance-ids $$id >/dev/null; \
	while :; do \
		st=$$($(AWS) ec2 describe-instances --instance-ids $$id --query "Reservations[0].Instances[0].State.Name" --output text); \
		printf '\r%s  EC2 %-10s ' "$$(date +%T)" "$$st"; \
		[ "$$st" = stopped ] && break; sleep 5; \
	done; echo; echo "Apagada (solo se siguen cobrando el disco y la IP fija)."

status:
	@$(AWS) ec2 describe-instances --instance-ids $(call out,instance_id) \
		--query "Reservations[0].Instances[0].State.Name" --output text

url:
	@echo $(call out,grafana_url)

password:
	@$(AWS) ssm get-parameter --name $(call out,grafana_password_parameter) --with-decryption \
		--query Parameter.Value --output text

# Ejecuta un comando en la EC2 por SSM (sin SSH) y muestra su salida.
define ssm_run
	@id=$$($(AWS) ssm send-command --instance-ids $(call out,instance_id) --document-name AWS-RunShellScript \
		--parameters 'commands=["cd /opt/monitoring && $(1)"]' \
		--query Command.CommandId --output text); \
	echo "SSM $$id: $(1)"; \
	$(AWS) ssm wait command-executed --command-id $$id --instance-id $(call out,instance_id) || true; \
	$(AWS) ssm get-command-invocation --command-id $$id --instance-id $(call out,instance_id) \
		--query "[Status,StandardOutputContent,StandardErrorContent]" --output text
endef

benchmark:
	@test "$(INGEST_DATE)" != "auto" || { echo "Falta INGEST_DATE (partición con la que se entrenó el champion)"; exit 1; }
	$(call ssm_run,./monitoring.sh run build_benchmark --ingest-date $(INGEST_DATE))

run:
	$(call ssm_run,./monitoring.sh run run_monitoring --ingest-date $(INGEST_DATE))

logs:
	$(call ssm_run,docker compose logs --tail 100 db frontend)

down: init
	$(TF) destroy -input=false $(TF_VARS) -target=aws_cloudfront_distribution.grafana \
		-target=aws_eip.server -target=aws_instance.server
