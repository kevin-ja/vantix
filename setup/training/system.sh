# Entrenamiento: lo lee setup/run.sh.
NAME="Entrenamiento"
MAKE_NAME="train"
REQUIRED=(SSO_START_URL SSO_REGION ACCOUNT_ID ROLE_NAME PROFILE GITHUB_REPO INGEST_DATE)
STEPS=""   # se completa en la fase 2
COST="💰 Deja encendida la EC2 de MLflow (~USD 0,02/h). La IP y el disco cobran siempre (~USD 5/mes).
   Para apagarla al terminar: make train-down"
NEXT="Sigue: entrenar y promover desde GitHub Actions (pasos 12 y 13 de pipelines/training/README.md)."
