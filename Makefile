# VANTIX · Makefile
#
# Infra (Terraform)
#   make up-training       levanta shared (si falta) + training
#   make up-inference      levanta shared (si falta) + inference
#   make down-training     baja solo training (shared queda)
#   make down-inference    baja solo inference (shared queda)
#   make down-shared       baja S3/MLflow (pide CONFIRM=yes)
#   make down-all          baja todo (pide CONFIRM=yes)
# MLflow (USD 0,60/h encendido)
#   make mlflow-stop | mlflow-start | mlflow-status
# Datos y pipeline de entrenamiento
#   make upload-raw        data/data.csv -> Parquet -> s3://.../raw/ingest_date=$(INGEST_DATE)/
#   make pipeline-upsert   crea/actualiza el pipeline en SageMaker
#   make pipeline-run      ejecuta el pipeline (SNAPSHOT_DATE, WINDOW_DAYS, K_MIN, K_MAX)
#   make promote RUN_ID=… SEGMENT_MAP=segment_maps/… REASON="…"   registra el run hijo como @champion y exporta
#   make rollback VERSION=… REASON="…"   @champion vuelve a una versión anterior y se re-exporta
#   make promote-export    re-exporta el @champion actual
#   make benchmark-freeze  copia (una sola vez) el champion v1 a models/benchmark/ (benchmark fijo)
# Pipeline de inferencia
#   make inference-upsert  crea/actualiza el pipeline en SageMaker
#   make inference-run     ejecuta el pipeline (fechas "auto" o SCORING_DATE, INF_SNAPSHOT, INF_INGEST)
#   make schedule-on | schedule-off   activa/apaga la corrida semanal (up-inference la deja apagada)
# Local
#   make venv | test | train-local
#   make promote-local RUN_ID=… SEGMENT_MAP=… REASON="…"   | inference-local
# Docs
#   make docs-env | diagrams    venv + Graphviz locales en docs/ -> docs/img/*.png
#
# "up" es idempotente: desde cero crea todo; con infra ya levantada solo aplica cambios.
# Sin confirmación interactiva: make up-training TF_ARGS=-auto-approve

AWS_PROFILE ?= vantix
REGION      ?= us-east-1
TF          := terraform
INFRA       := infra
TF_ARGS     ?=
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
export TF_VAR_aws_profile = $(AWS_PROFILE)
export TF_VAR_region      = $(REGION)

# Se evalúa una sola vez y solo si un target lo necesita (make help no llama a AWS).
ACCOUNT_ID   = $(eval ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text))$(ACCOUNT_ID)
STATE_BUCKET = vantix-$(ACCOUNT_ID)-tfstate
export TF_VAR_state_bucket = $(STATE_BUCKET)

.PHONY: help login bootstrap up-shared up-training up-inference down-training down-inference \
        down-shared down-all mlflow-stop mlflow-start mlflow-status upload-raw pipeline-upsert \
        pipeline-run promote rollback promote-export benchmark-freeze inference-upsert inference-run schedule-on schedule-off \
        venv test train-local promote-local inference-local docs-env diagrams

help:
	@sed -n '3,31p' Makefile | sed 's/^# \{0,1\}//'

login:
	aws sso login --profile $(AWS_PROFILE)

# --- helpers -----------------------------------------------------------------
define tf_init
	$(TF) -chdir=$(INFRA)/$(1) init -input=false -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="key=$(1)/terraform.tfstate" \
		-backend-config="region=$(REGION)" \
		-backend-config="profile=$(AWS_PROFILE)" \
		-backend-config="use_lockfile=true"
endef

define tf_up
	$(call tf_init,$(1))
	$(TF) -chdir=$(INFRA)/$(1) apply $(TF_ARGS)
endef

define tf_down
	$(call tf_init,$(1))
	$(TF) -chdir=$(INFRA)/$(1) destroy $(TF_ARGS)
endef

define require_confirm
	@test "$(CONFIRM)" = "yes" || { echo "Borra S3 (datos y modelos) y MLflow. Repite con CONFIRM=yes"; exit 1; }
endef

tf_output = $(shell $(TF) -chdir=$(INFRA)/$(1) output -raw $(2))

# --- bootstrap: bucket del estado de Terraform (idempotente, no se borra con down) ---
bootstrap:
	@aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null && echo "state bucket OK: $(STATE_BUCKET)" || { \
		aws s3api create-bucket --bucket $(STATE_BUCKET) --region $(REGION) && \
		aws s3api put-bucket-versioning --bucket $(STATE_BUCKET) --versioning-configuration Status=Enabled && \
		aws s3api put-public-access-block --bucket $(STATE_BUCKET) --public-access-block-configuration \
			BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true && \
		echo "state bucket creado: $(STATE_BUCKET)"; }

# --- up ----------------------------------------------------------------------
up-shared: bootstrap
	$(call tf_up,shared)

up-training: up-shared
	$(call tf_up,training)

up-inference: up-shared
	$(call tf_up,inference)

# --- down --------------------------------------------------------------------
down-training:
	$(call tf_down,training)

down-inference:
	$(call tf_down,inference)

down-shared:
	$(call require_confirm)
	$(call tf_down,shared)

down-all:
	$(call require_confirm)
	$(MAKE) down-training down-inference
	$(MAKE) down-shared CONFIRM=yes

# --- MLflow ------------------------------------------------------------------
MLFLOW_SERVER := vantix-mlflow

mlflow-stop:
	aws sagemaker stop-mlflow-tracking-server --tracking-server-name $(MLFLOW_SERVER) --region $(REGION)

mlflow-start:
	aws sagemaker start-mlflow-tracking-server --tracking-server-name $(MLFLOW_SERVER) --region $(REGION)

mlflow-status:
	@aws sagemaker describe-mlflow-tracking-server --tracking-server-name $(MLFLOW_SERVER) --region $(REGION) \
		--query '{status:TrackingServerStatus,url:TrackingServerUrl}' --output table

# --- datos y pipeline ----------------------------------------------------------
TRAINING_ENV = VANTIX_BUCKET=$(call tf_output,training,data_bucket) \
               VANTIX_ROLE_ARN=$(call tf_output,training,training_role_arn) \
               VANTIX_MLFLOW_ARN=$(call tf_output,training,mlflow_tracking_arn) \
               VANTIX_REGION=$(REGION)

upload-raw:
	$(PY) scripts/upload_raw.py --csv data/data.csv --bucket $(call tf_output,shared,data_bucket) \
		--ingest-date $(INGEST_DATE)

pipeline-upsert:
	$(TRAINING_ENV) $(PY) -m pipelines.training.pipeline_sagemaker upsert

pipeline-run:
	$(TRAINING_ENV) $(PY) -m pipelines.training.pipeline_sagemaker run \
		--ingest-date $(INGEST_DATE) --snapshot-date $(SNAPSHOT_DATE) \
		--window-days $(WINDOW_DAYS) --k-min $(K_MIN) --k-max $(K_MAX)

promote:
	@test -n "$(RUN_ID)" -a -n "$(SEGMENT_MAP)" -a -n "$(REASON)" || { echo 'Uso: make promote RUN_ID=<run hijo> SEGMENT_MAP=segment_maps/<snapshot>_k<k>.json REASON="…"'; exit 1; }
	MLFLOW_TRACKING_URI=$(call tf_output,training,mlflow_tracking_arn) \
		$(PY) -m pipelines.training.promote --run-id $(RUN_ID) --segment-map $(SEGMENT_MAP) --reason "$(REASON)" \
		--export-uri s3://$(call tf_output,shared,data_bucket)/models/champion

rollback:
	@test -n "$(VERSION)" -a -n "$(REASON)" || { echo 'Uso: make rollback VERSION=<versión del registry> REASON="…"'; exit 1; }
	MLFLOW_TRACKING_URI=$(call tf_output,training,mlflow_tracking_arn) \
		$(PY) -m pipelines.training.promote --version $(VERSION) --reason "$(REASON)" \
		--export-uri s3://$(call tf_output,shared,data_bucket)/models/champion

benchmark-freeze:
	$(PY) scripts/freeze_benchmark.py --bucket $(call tf_output,shared,data_bucket)

promote-export:
	MLFLOW_TRACKING_URI=$(call tf_output,training,mlflow_tracking_arn) \
		$(PY) -m pipelines.training.promote --export-only \
		--export-uri s3://$(call tf_output,shared,data_bucket)/models/champion

# --- pipeline de inferencia ------------------------------------------------------
INFERENCE_ENV = VANTIX_BUCKET=$(call tf_output,inference,data_bucket) \
                VANTIX_SCORES_BUCKET=$(call tf_output,inference,scores_bucket) \
                VANTIX_ROLE_ARN=$(call tf_output,inference,inference_role_arn) \
                VANTIX_REGION=$(REGION)

inference-upsert:
	$(INFERENCE_ENV) $(PY) -m pipelines.inference.pipeline_sagemaker upsert

# Con datos históricos: make inference-run INF_SNAPSHOT=2025-04-30 SCORING_DATE=2025-05-01
inference-run:
	$(INFERENCE_ENV) $(PY) -m pipelines.inference.pipeline_sagemaker run \
		--ingest-date $(INF_INGEST) --snapshot-date $(INF_SNAPSHOT) --scoring-date $(SCORING_DATE) \
		--window-days $(WINDOW_DAYS)

schedule-on:
	$(MAKE) up-inference TF_ARGS="$(TF_ARGS) -var=schedule_enabled=true"

schedule-off:
	$(MAKE) up-inference TF_ARGS="$(TF_ARGS) -var=schedule_enabled=false"

# --- local -------------------------------------------------------------------
venv:
	uv venv --python 3.11 .venv
	uv pip install --python $(PY) -r requirements-dev.txt

test:
	$(PY) -m pytest -q tests

# Corrida completa en local (sin AWS): MLflow en .local/mlflow.db (mlflow ui --backend-store-uri sqlite:///.local/mlflow.db)
train-local:
	$(PY) -m pipelines.training.steps.prepare --input data/data.csv --output-dir .local/prepare \
		--snapshot-date $(SNAPSHOT_DATE) --window-days $(WINDOW_DAYS)
	$(PY) -m pipelines.training.steps.train --features-dir .local/prepare/features \
		--metadata-dir .local/prepare/metadata --tracking-uri sqlite:///.local/mlflow.db \
		--k-min $(K_MIN) --k-max $(K_MAX)

# Promoción local: registra en .local/mlflow.db y exporta a .local/models/champion
promote-local:
	@test -n "$(RUN_ID)" -a -n "$(SEGMENT_MAP)" -a -n "$(REASON)" || { echo 'Uso: make promote-local RUN_ID=<run hijo> SEGMENT_MAP=<json> REASON="…"'; exit 1; }
	$(PY) -m pipelines.training.promote --tracking-uri sqlite:///.local/mlflow.db \
		--run-id $(RUN_ID) --segment-map $(SEGMENT_MAP) --reason "$(REASON)" --export-uri .local/models/champion

# Inferencia local: data/data.csv como raw/ingest_date=$(INGEST_DATE)/ -> .local/scores/
inference-local:
	mkdir -p .local/raw/ingest_date=$(INGEST_DATE)
	cp data/data.csv .local/raw/ingest_date=$(INGEST_DATE)/data.csv
	$(PY) -m pipelines.inference.steps.score --raw-uri .local/raw --champion-uri .local/models/champion \
		--output-uri .local/scores --ingest-date $(INF_INGEST) \
		--snapshot-date $(if $(filter auto,$(INF_SNAPSHOT)),$(SNAPSHOT_DATE),$(INF_SNAPSHOT)) \
		--scoring-date $(if $(filter auto,$(SCORING_DATE)),2025-05-01,$(SCORING_DATE)) \
		--window-days $(WINDOW_DAYS)

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
