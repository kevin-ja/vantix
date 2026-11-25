# Monitoreo: lo lee setup/run.sh.
NAME="Monitoreo"
MAKE_NAME="monitoring"
REQUIRED=(ACCOUNT_ID PROFILE GITHUB_REPO ALERT_EMAIL)
STEPS=""   # se completa en la fase 4
COST="💰 Deja encendida la EC2 de monitoreo (~USD 0,02/h). La IP y los discos cobran siempre (~USD 6/mes).
   Para apagarla al terminar: make monitoring-down"
NEXT="Sigue: construir el benchmark y correr el monitoreo (pasos 5 y 7 de monitorization/README.md)."
