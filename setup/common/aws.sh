# AWS: sesión, cuenta, bucket del estado, champion y lotes. Se carga con `.`; compatible con bash 3.2.

REGION="us-east-1"           # fija en los workflows
STATE_BUCKET="vantix-$ACCOUNT_ID-tfstate"

# El perfil manda: las llaves u otro perfil activos en la terminal podrían apuntar a otra cuenta.
use_profile() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
  export AWS_PROFILE="$PROFILE" AWS_PAGER=""
}

profile_exists() { env -u AWS_PROFILE aws configure list-profiles 2>/dev/null | grep -xF -- "$PROFILE" >/dev/null; }

whoami_aws() { aws sts get-caller-identity --profile "$PROFILE" --query Account --output text; }

# Se detiene si la cuenta de la sesión no es la de .env. Si la sesión venció, informa y abre el navegador.
check_aws() {
  local account
  command -v aws >/dev/null 2>&1 || die "Falta AWS CLI: corre primero make train-up."
  profile_exists || die "No existe el perfil de AWS '$PROFILE': corre primero make train-up."
  if ! spin "Comprobando la sesión de AWS" whoami_aws; then
    if [ "$SETUP_MODE" = "check" ]; then die "Sesión de AWS: vencida o sin iniciar. Iníciala con: aws sso login --profile $PROFILE"; fi
    info "La sesión de AWS venció: se abre el navegador para iniciarla."
    aws sso login --profile "$PROFILE" || die "No se pudo iniciar sesión (ver el error arriba)."
    spin "Comprobando la sesión de AWS" whoami_aws || { show_log; die "AWS no respondió."; }
  fi
  account="$(tail -n 1 "$LOG")"
  env_matches "$account" '^[0-9]{12}$' || die "AWS respondió una cuenta inesperada: $account"
  [ "$account" = "$ACCOUNT_ID" ] \
    || die "El perfil '$PROFILE' es de la cuenta $account y .env dice ACCOUNT_ID=$ACCOUNT_ID. No se cambió nada."
  ok "Cuenta de AWS: $ACCOUNT_ID (perfil $PROFILE)"
}

check_state_bucket() {
  spin "Buscando el bucket del estado" aws s3api head-bucket --bucket "$STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    || { show_log; die "No existe (o no es tuyo) el bucket $STATE_BUCKET: corre primero make train-up."; }
  ok "Bucket del estado: $STATE_BUCKET"
}

# Deja en BUCKET el bucket de datos (output de infra/shared, ya preparado con tf_init).
read_bucket() {
  spin "Buscando el bucket de datos" tf infra/shared output -raw data_bucket \
    || { show_log; die "La infraestructura de entrenamiento no está levantada: corre primero make train-up."; }
  BUCKET="$(tail -n 1 "$LOG")"
  # Sin infraestructura, `output` puede devolver un aviso en vez del nombre.
  env_matches "$BUCKET" '^[a-z0-9.-]{3,63}$' || die "La infraestructura de entrenamiento no está levantada: corre primero make train-up."
  ok "Bucket de datos: $BUCKET"
}

check_champion() {
  local file version k
  spin "Buscando el champion" aws s3api list-objects-v2 --bucket "$BUCKET" --prefix models/champion/ --query 'Contents[].Key' --output text \
    || { show_log; die "No se pudo leer models/champion/."; }
  for file in preprocessor.pkl model.pkl segment_map.json manifest.json; do
    tr '\t' '\n' < "$LOG" | grep -xF "models/champion/$file" >/dev/null \
      || die "No hay un champion completo (falta models/champion/$file): entrena y promueve un modelo (pasos 12 y 13 de pipelines/training/README.md)."
  done
  spin "Leyendo el champion" aws s3 cp --no-progress "s3://$BUCKET/models/champion/manifest.json" "$WORK/manifest.json" \
    || { show_log; die "No se pudo leer el champion."; }
  version="$(sed -nE 's/.*"model_version": *"?([0-9]+)"?.*/\1/p' "$WORK/manifest.json" | head -n 1)"
  k="$(sed -nE 's/.*"k": *([0-9]+).*/\1/p' "$WORK/manifest.json" | head -n 1)"
  ok "Champion: versión ${version:-?}, k=${k:-?}"
}

# Deja en LOTS las fechas de raw/, una por línea y en orden.
read_lots() {
  spin "Buscando lotes de datos" aws s3api list-objects-v2 --bucket "$BUCKET" --prefix raw/ --query 'Contents[].Key' --output text \
    || { show_log; die "No se pudo leer raw/."; }
  LOTS="$(tr '\t' '\n' < "$LOG" | sed -nE 's#^raw/ingest_date=([0-9]{4}-[0-9]{2}-[0-9]{2})/.+#\1#p' | sort -u)"
  [ -n "$LOTS" ] || die "No hay datos en raw/: corre primero make train-up."
  ok "Lotes de datos: $(printf '%s' "$LOTS" | paste -s -d ' ' -)"
}

# Deja en SCHEDULE el estado del scheduler de inferencia: ENABLED | DISABLED | falta.
SCHEDULE=""
read_schedule() {
  if spin "Leyendo el scheduler" aws scheduler get-schedule --region "$REGION" --name vantix-inference-weekly --query State --output text; then
    SCHEDULE="$(tail -n 1 "$LOG")"
    case "$SCHEDULE" in ENABLED|DISABLED) return 0 ;; esac
    die "AWS respondió un estado inesperado del scheduler: $SCHEDULE"
  fi
  grep 'ResourceNotFoundException' "$LOG" >/dev/null || { show_log; die "No se pudo leer el scheduler (ver el error arriba)."; }
  SCHEDULE="falta"
}
