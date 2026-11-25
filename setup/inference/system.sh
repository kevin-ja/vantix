# Inferencia: lo lee setup/run.sh.
NAME="Inferencia"
MAKE_NAME="inference"
REQUIRED=(ACCOUNT_ID PROFILE GITHUB_REPO)
STEPS="01_check 02_infra 03_github_vars"
COST="No deja nada encendido: solo se cobra S3 y cada corrida. El scheduler semanal se crea apagado."
NEXT="Sigue: desplegar el pipeline y puntuar (pasos 4 y 5 de pipelines/inference/README.md)."
