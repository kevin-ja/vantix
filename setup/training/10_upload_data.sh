# Paso: Dataset en S3
#
# Verifica data/data.parquet y lo sube a s3://vantix-<cuenta>-data/raw/ingest_date=<INGEST_DATE>/. Un lote no se sobrescribe.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

PY="$ROOT/.venv/bin/python"
DATA="$ROOT/data/data.parquet"
KEY="raw/ingest_date=$INGEST_DATE/data.parquet"

# Deja en LOT: falta | igual | distinto.
LOT=""; BUCKET=""
read_lot() {
  local remote
  LOT="falta"
  # Se lista (en vez de head-object) para distinguir "no está" de un error de permisos.
  spin "Buscando el lote $INGEST_DATE en S3" aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$KEY" \
    --query 'Contents[].Key' --output text || { show_log; die "No se pudo leer el bucket $BUCKET."; }
  grep -F -- "$KEY" "$LOG" >/dev/null || return 0
  spin "Comparando con tu archivo" aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query Metadata.sha256 --output text \
    || { show_log; die "No se pudo leer el lote en S3."; }
  remote="$(tail -n 1 "$LOG")"
  if [ "$remote" = "$(sha256_of "$DATA")" ]; then LOT="igual"; else LOT="distinto"; fi
}

review() {
  [ -x "$PY" ]   || die "Falta el entorno de Python (.venv)."
  [ -f "$DATA" ] || die "Falta el dataset (data/data.parquet)."
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  read_lot
  case "$LOT" in
    igual)    ok "El lote $INGEST_DATE está en S3 y es idéntico a tu archivo" ;;
    distinto) die "El lote $INGEST_DATE ya existe en S3 con otro archivo y no se sobrescribe. Usa otra fecha: INGEST_DATE en .env" ;;
    falta)    todo "El lote $INGEST_DATE no está en S3" ;;
  esac
}

apply() {
  spin "Verificando el dataset" "$PY" "$ROOT/scripts/check_data.py" "$DATA" \
    || { show_log; die "El dataset no pasó la comprobación (ver el error arriba). No se subió nada."; }
  info "Subiendo data/data.parquet a s3://$BUCKET/$KEY. Un lote no se puede sobrescribir después."
  spin "Subiendo el dataset" "$PY" "$ROOT/scripts/upload_raw.py" --input "$DATA" --bucket "$BUCKET" --ingest-date "$INGEST_DATE" \
    || { show_log; die "No se pudo subir (ver el error arriba)."; }
  ok "$(tail -n 1 "$LOG")"
}

verify() {
  spin "Comprobando el lote en S3" aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text \
    || { show_log; die "El lote no está en S3."; }
  ok "s3://$BUCKET/$KEY ($(tail -n 1 "$LOG") bytes)"
}

run_step
