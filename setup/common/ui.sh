# Salida en pantalla, confirmaciones y registro. Se carga con `.`; compatible con bash 3.2, el de macOS.

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi

LOG=""; SPIN_PID=""; WORK=""      # LOG: salida del último comando; WORK: carpeta temporal del paso

# Nada que parezca una credencial llega al registro.
redact() {
  sed -E -e 's/(gh[opsur]_|github_pat_)[A-Za-z0-9_]+/[oculto]/g' -e 's/(AKIA|ASIA)[A-Z0-9]{16}/[oculto]/g' \
    -e 's/(([Pp]assword|[Ss]ecret|[Tt]oken)[A-Za-z_]*"?[[:space:]]*[=:][[:space:]]*).+/\1[oculto]/'
}
record()     { if [ -n "$SETUP_LOG" ]; then printf '%s\n' "$*" | redact >> "$SETUP_LOG"; fi; }
record_log() { if [ -n "$SETUP_LOG" ] && [ -s "$LOG" ]; then redact < "$LOG" | sed 's/^/    | /' >> "$SETUP_LOG"; fi; }

title() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; record "" "$*"; }
info()  { printf '  → %s\n' "$*"; record "  → $*"; }
ok()    { printf '  %s✔%s %s\n' "$GREEN" "$OFF" "$*"; record "  ✔ $*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$*"; record "  ! $*"; }
err()   { printf '  %s✘%s %s\n' "$RED" "$OFF" "$*" >&2; record "  ✘ $*"; }
die()   { err "$*"; exit 1; }

# El final del error; la salida completa queda en el registro.
show_log() { tail -n 25 "$LOG" | sed 's/^/    /' >&2; }

cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if declare -F step_cleanup >/dev/null; then step_cleanup; fi   # lo propio del paso
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

# spin "qué está haciendo" comando… -> muestra la espera con los segundos y borra la línea al terminar.
# Devuelve el resultado del comando; su salida queda en $LOG.
spin() {
  local msg="$1" rc n=0 start=$SECONDS frames='|/-\'
  shift
  record "  · $msg"
  if [ ! -t 1 ]; then
    "$@" >"$LOG" 2>&1 </dev/null
    rc=$?
  else
    "$@" >"$LOG" 2>&1 </dev/null &
    SPIN_PID=$!
    while kill -0 "$SPIN_PID" 2>/dev/null; do
      printf '\r  %s %s… %ss\033[K' "${frames:$((n % 4)):1}" "$msg" "$((SECONDS - start))"
      n=$((n + 1))
      sleep 0.2
    done
    wait "$SPIN_PID"
    rc=$?
    SPIN_PID=""
    printf '\r\033[K'
  fi
  record_log
  return "$rc"
}

# task "qué está haciendo" "qué quedó hecho" comando… -> ✔, o ✘ con el error exacto.
task() {
  local doing="$1" done_msg="$2"
  shift 2
  if spin "$doing" "$@"; then ok "$done_msg"; return 0; fi
  err "$doing: falló"
  show_log
  return 1
}

# live <filtro> comando… -> muestra en vivo lo que deje pasar el filtro; la salida completa queda en $LOG.
live() {
  local rc filter="$1"
  shift
  "$@" 2>&1 </dev/null | tee "$LOG" | "$filter"
  rc=${PIPESTATUS[0]}
  record_log
  return "$rc"
}

# confirm "pregunta" -> 0 si responde y, 1 si responde n. Con `check` nunca pregunta: siempre es n.
confirm() {
  local answer
  if [ "$SETUP_MODE" = "check" ]; then return 1; fi
  while true; do
    printf '%s%s [y/n]: %s' "$BOLD" "$1" "$OFF"
    read -r answer || return 1
    case "$answer" in
      y|Y) record "  ? $1 y"; return 0 ;;
      n|N) record "  ? $1 n"; return 1 ;;
      *)   echo "Responde y o n." ;;
    esac
  done
}
