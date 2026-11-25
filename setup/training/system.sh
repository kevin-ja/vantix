# Entrenamiento: lo lee setup/run.sh.
NAME="Entrenamiento"
MAKE_NAME="train"
REQUIRED=(SSO_START_URL SSO_REGION ACCOUNT_ID ROLE_NAME PROFILE GITHUB_REPO INGEST_DATE)
STEPS="01_tools 02_aws_session 03_python 04_github_repo 05_dataset 06_environment_quota 07_state_bucket 08_mlflow
       09_infra 10_upload_data 11_github_vars"
COST="💰 Deja encendida la EC2 de MLflow (~USD 0,02/h). La IP y el disco cobran siempre (~USD 5/mes).
   Para apagarla al terminar: make train-down"
NEXT="Sigue: entrenar y promover desde GitHub Actions (pasos 12 y 13 de pipelines/training/README.md)."
