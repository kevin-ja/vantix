# Paso: Lote de prueba
#
# Opcional, solo si no tienes datos nuevos:
#   make monitoring-sample-batch TIPO=estable        se parece al benchmark: 0 alertas        (lote 2025-06-30)
#   make monitoring-sample-batch TIPO=degradado      problemas a propósito: muchas alertas    (lote 2025-07-31)
#   LOTE=AAAA-MM-DD                                  otra etiqueta de lote
# CUIDADO: un lote no se puede sobrescribir y, si su fecha es la más reciente, pasa a ser "el último". Por eso pregunta.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

PY="$ROOT/.venv/bin/python"
DATA="$ROOT/data/data.parquet"

review() {
  case "$TIPO" in
    estable)   LOTE="${LOTE:-2025-06-30}" ;;
    degradado) LOTE="${LOTE:-2025-07-31}" ;;
    *) die "Indica el lote: make monitoring-sample-batch TIPO=estable (o TIPO=degradado)" ;;
  esac
  env_date "$LOTE" || die "LOTE debe ser una fecha real con la forma 2025-06-30: $LOTE"
  [ -x "$PY" ]   || die "Falta el entorno de Python (.venv): corre primero make train-up."
  [ -f "$DATA" ] || die "Falta el dataset (data/data.parquet): corre primero make train-up."
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  read_lots
  if printf '%s\n' "$LOTS" | grep -xF "$LOTE" >/dev/null; then
    ok "El lote $LOTE ya existe y no se sobrescribe: no hay nada que subir. Si querías otro, usa LOTE=AAAA-MM-DD."
  else
    todo "El lote $LOTE no está en S3"
  fi
}

generate() {
  local stable="$LOTE" degraded="$LOTE" skip="2000-01-31"
  if [ "$TIPO" = "estable" ]; then degraded="$skip"; else stable="$skip"; fi
  "$PY" "$ROOT/monitorization/scripts/make_synthetic_batches.py" --raw "$DATA" --out "$WORK/raw" \
    --stable-ingest "$stable" --degraded-ingest "$degraded"
}

apply() {
  local file newest
  echo "  Se generará un lote sintético ($TIPO) y se subirá a s3://$BUCKET/raw/ingest_date=$LOTE/"
  warn "Son datos de PRUEBA y quedan junto a los reales. Un lote no se puede sobrescribir."
  newest="$(printf '%s\n' "$LOTS" | tail -n 1)"
  # Las fechas AAAA-MM-DD se ordenan como texto.
  if [ "$(printf '%s\n%s\n' "$newest" "$LOTE" | sort | tail -n 1)" = "$LOTE" ]; then
    warn "Pasará a ser el ÚLTIMO lote (hoy es $newest): la inferencia y el monitoreo lo usarán si se lanzan con fechas auto."
  fi
  confirm "¿Subirlo?" || die "No se subió nada."
  spin "Generando el lote" generate || { show_log; die "No se pudo generar el lote (ver el error arriba)."; }
  file="$WORK/raw/ingest_date=$LOTE/data.parquet"
  [ -f "$file" ] || die "El generador no creó el lote esperado."
  ok "Lote generado"
  spin "Subiendo el lote" "$PY" "$ROOT/scripts/upload_raw.py" --input "$file" --bucket "$BUCKET" --ingest-date "$LOTE" \
    || { show_log; die "No se pudo subir (ver el error arriba)."; }
  ok "$(tail -n 1 "$LOG")"
}

verify() {
  read_lots
  printf '%s\n' "$LOTS" | grep -xF "$LOTE" >/dev/null || die "El lote no aparece en S3."
  ok "Para correr el monitoreo usa ingest_date = $LOTE"
}

run_step
