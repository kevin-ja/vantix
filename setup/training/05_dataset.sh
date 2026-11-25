# Paso: Dataset
#
# Descarga data/data.parquet del GitHub Release y lo verifica (SHA-256 + las reglas del pipeline, scripts/check_data.py).
# Solo reemplaza al archivo actual si la descarga llegó completa. Otro origen: DATA_REPO=usuario/repo DATA_RELEASE=etiqueta
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

# Los releases no se copian a los forks: por defecto se usa el repo original.
DATA_REPO="${DATA_REPO:-kevin-ja/vantix}"
DATA_RELEASE="${DATA_RELEASE:-data-v1}"
URL="https://github.com/$DATA_REPO/releases/download/$DATA_RELEASE"
PY="$ROOT/.venv/bin/python"
DATA="$ROOT/data/data.parquet"
SHA="$DATA.sha256"
step_cleanup() { rm -f "$DATA.part.$$"; }

EXPECTED=""   # SHA-256 publicado en el release
read_published_sha() {
  spin "Leyendo el SHA-256 publicado" curl -fsSL --connect-timeout 20 --retry 3 -o "$WORK/sha256" "$URL/data.parquet.sha256" || return 1
  EXPECTED="$(awk 'NR == 1 {print $1}' "$WORK/sha256")"
  env_matches "$EXPECTED" '^[0-9a-f]{64}$' || die "El SHA-256 publicado en $URL no es válido. No se cambió nada."
}

local_sha() { awk 'NR == 1 {print $1}' "$SHA" 2>/dev/null; }

check_data() {
  spin "Verificando el dataset (mismas reglas que el pipeline)" "$PY" "$ROOT/scripts/check_data.py" "$DATA" \
    || { show_log; die "El dataset no pasó la comprobación (ver el error arriba)."; }
  ok "$(sed -nE 's/.*DATA OK: (.*)/Dataset verificado: \1/p' "$LOG")"
}

DO_DOWNLOAD=0; DO_SHA=0; REPLACE=0
review() {
  local actual="" offline=0
  DO_DOWNLOAD=0; DO_SHA=0; REPLACE=0
  env_matches "$DATA_REPO/$DATA_RELEASE" '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
    || die "DATA_REPO o DATA_RELEASE no son válidos: $DATA_REPO, $DATA_RELEASE"
  have curl || die "Falta curl."
  [ -x "$PY" ] || die "Falta el entorno de Python (.venv)."
  if [ -d "$DATA" ] || [ -d "$SHA" ]; then die "$DATA o su .sha256 es una carpeta. No se cambió nada."; fi
  if ! read_published_sha; then show_log; offline=1; fi
  if [ -f "$DATA" ]; then
    spin "Calculando el SHA-256 de tu archivo" sha256_of "$DATA" || { show_log; die "No se pudo leer $DATA."; }
    actual="$(tail -n 1 "$LOG")"
  fi
  if [ "$offline" -eq 1 ]; then
    # Sin release no se puede descargar, pero un archivo ya descargado y completo sirve igual.
    if [ -n "$actual" ] && [ "$(local_sha)" = "$actual" ]; then
      warn "No se pudo consultar $URL, pero tu archivo está completo: se usa ese"
    else
      die "No se pudo consultar $URL. Revisa tu conexión (y DATA_REPO / DATA_RELEASE)."
    fi
  elif [ -z "$actual" ]; then
    todo "data/data.parquet: no existe"
    DO_DOWNLOAD=1
    return 0
  elif [ "$actual" != "$EXPECTED" ]; then
    todo "data/data.parquet: existe, pero está incompleto o es de otra versión"
    DO_DOWNLOAD=1; REPLACE=1
    return 0
  elif [ "$(local_sha)" != "$EXPECTED" ]; then
    # El .sha256 puede faltar o ser de otra versión aunque los datos estén bien.
    todo "data/data.parquet.sha256: falta o es de otra versión"
    DO_SHA=1
    return 0
  fi
  check_data
}

apply() {
  local actual
  if [ "$DO_SHA" -eq 1 ]; then cp "$WORK/sha256" "$SHA" || die "No se pudo escribir $SHA."; fi
  if [ "$DO_DOWNLOAD" -eq 0 ]; then return 0; fi
  mkdir -p "$ROOT/data" || die "No se pudo crear $ROOT/data."
  info "Descargando data.parquet (~20 MB) de $URL"
  curl -fL --connect-timeout 20 --retry 3 --progress-bar -o "$DATA.part.$$" "$URL/data.parquet" \
    || die "La descarga falló (ver el error arriba). Lo que tenías queda igual."
  spin "Verificando el SHA-256" sha256_of "$DATA.part.$$" || { show_log; die "No se pudo leer la descarga."; }
  actual="$(tail -n 1 "$LOG")"
  [ "$actual" = "$EXPECTED" ] \
    || die "La descarga llegó incompleta o dañada (esperado $EXPECTED, recibido $actual). Lo que tenías queda igual."
  ok "Descarga completa (SHA-256 correcto)"
  if [ "$REPLACE" -eq 1 ]; then
    actual="$DATA.anterior.$(date +%Y%m%d%H%M%S)"
    mv "$DATA" "$actual" || die "No se pudo guardar tu archivo actual. No se cambió nada."
    info "Tu archivo anterior quedó en ${actual#"$ROOT"/}"
  fi
  mv "$DATA.part.$$" "$DATA" && cp "$WORK/sha256" "$SHA" || die "No se pudo guardar el dataset en data/."
  ok "Guardado en data/data.parquet"
}

run_step
