# VANTIX · Makefile
#
# Setup (datos en .env: cp .env.example .env)
#   make train-up          levanta entrenamiento desde cero: herramientas, sesiones, MLflow, infra, datos y GitHub
#   make train-check       solo lee: qué está listo y qué falta
#   make train-down        apaga la EC2 de MLflow; no borra nada
#   make inference-up      levanta inferencia (exige un @champion): bucket de scores, roles, scheduler apagado y GitHub
#   make inference-check   solo lee · make inference-down   apaga la corrida semanal; no borra nada
#   Monitorización: por ahora, con monitorization/setup
#   make bootstrap         bucket del estado de Terraform (train-up ya lo hace)
# MLflow propio (EC2 de mlflow_server/; ~USD 0,03/h encendido, arranca en ~30 s)
#   make mlflow-start | mlflow-stop | mlflow-status
# Datos y pipeline de entrenamiento
#   make get-data          descarga data/data.parquet del GitHub Release (DATA_RELEASE) y lo verifica
#   make check-data        verifica data/data.parquet (SHA-256 + validación del pipeline)
#   make upload-data       verifica y sube data/data.parquet a s3://.../raw/ingest_date=$(INGEST_DATE)/
#   make pipeline-upsert   crea/actualiza el pipeline en SageMaker
#   make pipeline-run      ejecuta el pipeline (SNAPSHOT_DATE, WINDOW_DAYS, K_MIN, K_MAX)
#   make promote RUN_ID=… SEGMENT_MAP=segment_maps/… REASON="…"   registra el run hijo como @champion y exporta
#   make rollback VERSION=… REASON="…"   @champion vuelve a una versión anterior y se re-exporta
#   make promote-export    re-exporta el @champion actual
#   make benchmark-freeze  copia (una sola vez) el champion v1 a models/benchmark/ (benchmark fijo)
# Pipeline de inferencia
#   make inference-upsert  crea/actualiza el pipeline en SageMaker
#   make inference-run     ejecuta el pipeline (fechas "auto" o SCORING_DATE, INF_SNAPSHOT, INF_INGEST)
#   make schedule-on | schedule-off   activa (pregunta antes) / apaga la corrida semanal
# Desarrollo (entorno, tests y lint; lo mismo corre en CI)
#   make venv | test | lint
# MLflow propio (mlflow_server/, ver mlflow_server/README.md)
#   make mlflow-server-<target>   p. ej. mlflow-server-up | -start | -stop | -status | -smoke | -recreate-test
# Docs
#   make docs-env | diagrams    venv + Graphviz locales en docs/ -> docs/img/*.png

AWS_PROFILE ?= vantix
REGION      ?= us-east-1
TF          := terraform
INFRA       := infra
PY          := .venv/bin/python

INGEST_DATE   ?= 2025-04-30
SNAPSHOT_DATE ?= 2025-04-30
WINDOW_DAYS   ?= 30
K_MIN         ?= 2
K_MAX         ?= 10
SCORING_DATE  ?= auto
INF_SNAPSHOT  ?= auto
INF_INGEST    ?= auto

export AWS_PROFILE

# Se evalúa una sola vez y solo si un target lo necesita (make help no llama a AWS).
ACCOUNT_ID   = $(eval ACCOUNT_ID := $(shell aws sts get-caller-identity --profile $(AWS_PROFILE) --query Account --output text 2>/dev/null))$(ACCOUNT_ID)
STATE_BUCKET = vantix-$(ACCOUNT_ID)-tfstate

.PHONY: help train-up train-check train-down inference-up inference-check inference-down login bootstrap mlflow-stop mlflow-start mlflow-status get-data check-data upload-data pipeline-upsert \
        pipeline-run check-clean promote rollback promote-export benchmark-freeze inference-upsert inference-run schedule-on schedule-off \
        venv test lint docs-env diagrams

help:
	@sed -n '3,32p' Makefile | sed 's/^# \{0,1\}//'

login:
	aws sso login --profile $(AWS_PROFILE)

# --- setup: la lógica vive en setup/ (ver planning-setup.md) --------------------
train-up:
	@bash setup/run.sh up training

train-check:
	@bash setup/run.sh check training

train-down:
	@bash setup/run.sh down training

inference-up:
	@bash setup/run.sh up inference

inference-check:
	@bash setup/run.sh check inference

inference-down:
	@bash setup/run.sh down inference

# --- helpers -----------------------------------------------------------------
tf_output = $(shell $(TF) -chdir=$(INFRA)/$(1) output -raw $(2))

# --- bootstrap: bucket del estado de Terraform (idempotente) ---
bootstrap:
	@aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null && echo "state bucket OK: $(STATE_BUCKET)" || { \
		aws s3api create-bucket --bucket $(STATE_BUCKET) --region $(REGION) && \
		aws s3api put-bucket-versioning --bucket $(STATE_BUCKET) --versioning-configuration Status=Enabled && \
		aws s3api put-public-access-block --bucket $(STATE_BUCKET) --public-access-block-configuration \
			BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true && \
		echo "state bucket creado: $(STATE_BUCKET)"; }

# --- MLflow propio (mlflow_server/): la EC2 se busca por su tag Name (el id cambia al reemplazarse) ----
MLFLOW_INSTANCE_NAME := vantix-mlflow-server
MLFLOW_INSTANCE = $(shell aws ec2 describe-instances --profile $(AWS_PROFILE) --region $(REGION) \
	--filters Name=tag:Name,Values=$(MLFLOW_INSTANCE_NAME) Name=instance-state-name,Values=pending,running,stopping,stopped \
	--query 'Reservations[0].Instances[0].InstanceId' --output text)
MLFLOW_URI = $(call tf_output,shared,mlflow_tracking_uri)
# Clientes locales: la contraseña se lee de SSM (pipelines/common/mlflow_auth.py).
MLFLOW_ENV = MLFLOW_TRACKING_URI=$(MLFLOW_URI) MLFLOW_TRACKING_PASSWORD_PARAM=$(call tf_output,shared,mlflow_password_param)

mlflow-start:
	aws ec2 start-instances --instance-ids $(MLFLOW_INSTANCE) --region $(REGION) --query 'StartingInstances[0].CurrentState.Name' --output text
	@for i in $$(seq 1 40); do [ "$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $(MLFLOW_URI)/health)" = 200 ] && \
		{ echo "MLflow listo: $(MLFLOW_URI)"; exit 0; }; sleep 5; done; echo "MLflow no respondió"; exit 1

mlflow-stop:
	aws ec2 stop-instances --instance-ids $(MLFLOW_INSTANCE) --region $(REGION) --query 'StoppingInstances[0].CurrentState.Name' --output text

mlflow-status:
	@echo "EC2:    $$(aws ec2 describe-instances --instance-ids $(MLFLOW_INSTANCE) --region $(REGION) --query 'Reservations[0].Instances[0].State.Name' --output text)"
	@echo "MLflow: $$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $(MLFLOW_URI)/health) (200 = arriba) · $(MLFLOW_URI)"

# --- trazabilidad: solo se sube a SageMaker código commiteado y pusheado ----------------
# El git_commit que registran MLflow y summary.json debe existir en GitHub (docs/arch_mlops.md).
check-clean:
	@test -z "$$(git status --porcelain -- pipelines)" || { \
		echo "Hay cambios sin commitear en pipelines/: haz commit y push antes de correr en AWS"; \
		git status --short -- pipelines; exit 1; }
	@git fetch -q origin && git branch -r --contains HEAD | grep -q . || { \
		echo "El commit $$(git rev-parse --short HEAD) no está en GitHub: haz git push antes de correr en AWS"; exit 1; }

# --- datos y pipeline ----------------------------------------------------------
TRAINING_ENV = VANTIX_BUCKET=$(call tf_output,training,data_bucket) \
               VANTIX_ROLE_ARN=$(call tf_output,training,training_role_arn) \
               VANTIX_MLFLOW_URI=$(call tf_output,training,mlflow_tracking_uri) \
               VANTIX_MLFLOW_PASSWORD_PARAM=$(call tf_output,training,mlflow_password_param) \
               VANTIX_REGION=$(REGION)

# Dataset público: adjunto del GitHub Release $(DATA_RELEASE) del repo original (los forks no copian releases).
DATA_REPO    ?= kevin-ja/vantix
DATA_RELEASE ?= data-v1
DATA_URL      = https://github.com/$(DATA_REPO)/releases/download/$(DATA_RELEASE)
DATA_FILE    := data/data.parquet

get-data:
	@mkdir -p data
	@echo "Downloading dataset ($(DATA_RELEASE)) from $(DATA_URL)/"
	@curl -fL --progress-bar -o $(DATA_FILE).part $(DATA_URL)/data.parquet || { rm -f $(DATA_FILE).part; \
		echo "✘ DOWNLOAD FAILED: $(DATA_URL)/data.parquet (check your internet connection and DATA_REPO / DATA_RELEASE)"; exit 1; }
	@curl -fsSL -o $(DATA_FILE).sha256 $(DATA_URL)/data.parquet.sha256 || { rm -f $(DATA_FILE).part; \
		echo "✘ DOWNLOAD FAILED: $(DATA_URL)/data.parquet.sha256"; exit 1; }
	@mv $(DATA_FILE).part $(DATA_FILE)
	@$(MAKE) --no-print-directory check-data

check-data:
	@$(PY) scripts/check_data.py $(DATA_FILE)

upload-data: check-data
	$(PY) scripts/upload_raw.py --input $(DATA_FILE) --bucket $(call tf_output,shared,data_bucket) \
		--ingest-date $(INGEST_DATE)

pipeline-upsert: check-clean
	$(TRAINING_ENV) $(PY) -m pipelines.training.pipeline_sagemaker upsert

pipeline-run: check-clean
	$(TRAINING_ENV) $(PY) -m pipelines.training.pipeline_sagemaker run \
		--ingest-date $(INGEST_DATE) --snapshot-date $(SNAPSHOT_DATE) \
		--window-days $(WINDOW_DAYS) --k-min $(K_MIN) --k-max $(K_MAX)

promote:
	@test -n "$(RUN_ID)" -a -n "$(SEGMENT_MAP)" -a -n "$(REASON)" || { echo 'Uso: make promote RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/<snapshot>_k<k>.json REASON="…"'; exit 1; }
	$(MLFLOW_ENV) \
		$(PY) -m pipelines.training.promote --run-id $(RUN_ID) --segment-map $(SEGMENT_MAP) --reason "$(REASON)" \
		--export-uri s3://$(call tf_output,shared,data_bucket)/models/champion

rollback:
	@test -n "$(VERSION)" -a -n "$(REASON)" || { echo 'Uso: make rollback VERSION=<versión del registry> REASON="…"'; exit 1; }
	$(MLFLOW_ENV) \
		$(PY) -m pipelines.training.promote --version $(VERSION) --reason "$(REASON)" \
		--export-uri s3://$(call tf_output,shared,data_bucket)/models/champion

benchmark-freeze:
	$(PY) scripts/freeze_benchmark.py --bucket $(call tf_output,shared,data_bucket)

promote-export:
	$(MLFLOW_ENV) \
		$(PY) -m pipelines.training.promote --export-only \
		--export-uri s3://$(call tf_output,shared,data_bucket)/models/champion

# --- pipeline de inferencia ------------------------------------------------------
INFERENCE_ENV = VANTIX_BUCKET=$(call tf_output,inference,data_bucket) \
                VANTIX_SCORES_BUCKET=$(call tf_output,inference,scores_bucket) \
                VANTIX_ROLE_ARN=$(call tf_output,inference,inference_role_arn) \
                VANTIX_REGION=$(REGION)

inference-upsert: check-clean
	$(INFERENCE_ENV) $(PY) -m pipelines.inference.pipeline_sagemaker upsert

# Con datos históricos: make inference-run INF_SNAPSHOT=2025-04-30 SCORING_DATE=2025-05-01
inference-run: check-clean
	$(INFERENCE_ENV) $(PY) -m pipelines.inference.pipeline_sagemaker run \
		--ingest-date $(INF_INGEST) --snapshot-date $(INF_SNAPSHOT) --scoring-date $(SCORING_DATE) \
		--window-days $(WINDOW_DAYS)

schedule-on:
	@bash setup/run.sh only inference 06_schedule_on

schedule-off:
	@bash setup/run.sh down inference

# --- desarrollo --------------------------------------------------------------
venv:
	uv venv --python 3.11 .venv
	uv pip install --python $(PY) -r requirements-dev.txt

test:
	$(PY) -m pytest -q tests

lint:
	.venv/bin/ruff check .
	$(TF) fmt -check -recursive $(INFRA) mlflow_server/infra

# --- docs: diagramas (todo local al repo: docs/.venv + Graphviz en docs/.tools) ----
DOCS_PY  := docs/.venv/bin/python
GRAPHVIZ := docs/.tools/graphviz/bin

docs-env:
	uv venv --python 3.11 docs/.venv
	uv pip install --python $(DOCS_PY) -r docs/requirements.txt
	@test -x docs/.tools/bin/micromamba || { mkdir -p docs/.tools && \
		curl -fsSL https://micro.mamba.pm/api/micromamba/osx-arm64/latest | tar -xj -C docs/.tools bin/micromamba; }
	MAMBA_ROOT_PREFIX=$(CURDIR)/docs/.tools/mamba docs/.tools/bin/micromamba create -y -q \
		-p $(CURDIR)/docs/.tools/graphviz -c conda-forge graphviz

diagrams:
	PATH="$(CURDIR)/$(GRAPHVIZ):$$PATH" $(DOCS_PY) docs/training_pipeline_diagram.py
	PATH="$(CURDIR)/$(GRAPHVIZ):$$PATH" $(DOCS_PY) docs/inference_pipeline_diagram.py

# --- MLflow propio: delega en mlflow_server/Makefile (autocontenido) ------------------------
mlflow-server-%:
	$(MAKE) -C mlflow_server $* NAME=vantix-mlflow AWS_PROFILE=$(AWS_PROFILE) REGION=$(REGION) \
		STATE_BUCKET=$(STATE_BUCKET)

