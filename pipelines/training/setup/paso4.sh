#!/usr/bin/env bash
# Paso 4 · Autorizar tu repo para que GitHub Actions pueda entrar a AWS (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso4.sh                      # detecta tu repo por el remoto "origin"
#   bash pipelines/training/setup/paso4.sh --repo=ana/vantix    # o se indica a mano
#
# 1. Revisa tu sesión de GitHub; si no hay, la inicia en el navegador.
# 2. Detecta tu repo, comprueba que lo administras y pregunta a GitHub cómo se identifica ante AWS (OIDC).
# 3. Guarda ese valor (github_repo) en los terraform.tfvars que lee Terraform.
# 4. Comprueba el resultado.
#
# No cambia nada en AWS ni en GitHub, y no pide contraseñas ni tokens. Antes de cambiar algo pregunta (y/n).
# Se puede correr varias veces: no duplica líneas y conserva las demás variables de cada archivo.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
TFVARS=("infra/shared/terraform.tfvars" "monitorization/infra/terraform.tfvars")   # módulos con roles de GitHub
REPO=""          # owner/repo
VALUE=""         # como se identifica ante AWS: owner@id/repo@id u owner/repo
unset GH_PROMPT_DISABLED   # gh debe poder preguntar durante el inicio de sesión
export GH_PAGER="cat"

# --- salida -------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi
stage() { printf '\n%s━━ Etapa %s/4 · %s ━━%s\n' "$BOLD" "$1" "$2" "$OFF"; }
title() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }
info()  { printf '  → %s\n' "$*"; }
ok()    { printf '  %s✔%s %s\n' "$GREEN" "$OFF" "$*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
err()   { printf '  %s✘%s %s\n' "$RED" "$OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }

LOG=""; SPIN_PID=""; PART=""
cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if [ -n "$LOG" ]; then rm -f "$LOG"; fi
  if [ -n "$PART" ]; then rm -f "$PART"; fi
}
show_log() { sed 's/^/    /' "$LOG" >&2; }

# spin "qué está haciendo" comando… -> muestra la espera con los segundos y borra la línea al terminar.
# Devuelve el resultado del comando; su salida queda en $LOG.
spin() {
  local msg="$1" rc n=0 start=$SECONDS frames='|/-\'
  shift
  if [ ! -t 1 ]; then "$@" >"$LOG" 2>&1 </dev/null; return; fi
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
  return "$rc"
}

# confirm "pregunta" -> 0 si responde y, 1 si responde n
confirm() {
  local answer
  while true; do
    printf '%s%s [y/n]: %s' "$BOLD" "$1" "$OFF"
    read -r answer || return 1
    case "$answer" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *)   echo "Responde y o n." ;;
    esac
  done
}

valid_repo() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' >/dev/null; }

# --- 1. cuenta de GitHub ------------------------------------------------------
USER_LOGIN=""

# Si el error no es de autenticación, iniciar sesión no lo arregla: se detiene y lo muestra.
stop_if_offline() {
  if grep -iE 'error connecting|could not resolve|no such host|timeout|timed out|HTTP 5[0-9][0-9]|rate limit' "$LOG" >/dev/null; then
    show_log
    die "GitHub no respondió. Revisa tu conexión y vuelve a correr este script."
  fi
}

# Deja en USER_LOGIN la cuenta activa. `gh auth status` no sirve: falla si otra cuenta guardada está vencida.
read_login() {
  USER_LOGIN=""
  if spin "Comprobando tu sesión de GitHub" gh api --hostname github.com user --jq .login; then
    USER_LOGIN="$(tail -n 1 "$LOG")"
    return 0
  fi
  stop_if_offline
  return 1
}

login() {
  if [ -n "$GH_TOKEN$GITHUB_TOKEN" ]; then
    die "Tu terminal tiene GH_TOKEN o GITHUB_TOKEN, que mandan sobre el inicio de sesión. Quítalas: unset GH_TOKEN GITHUB_TOKEN"
  fi
  info "Copia el código que aparecerá, pulsa Enter y pégalo en el navegador para autorizar el acceso."
  echo
  gh auth login --hostname github.com --git-protocol https --web || return 1
  echo
  read_login
}

ensure_login() {
  if read_login; then ok "Cuenta de GitHub: $USER_LOGIN"; return 0; fi
  err "Cuenta de GitHub: sin sesión, o con la sesión vencida"
  echo
  confirm "¿Iniciar sesión en GitHub?" || { echo "No se cambió nada."; exit 1; }
  login || die "No se pudo iniciar sesión (ver el error arriba). Vuelve a correr este script para reintentar."
  ok "Cuenta de GitHub: $USER_LOGIN"
}

# --- 2. repo ------------------------------------------------------------------
# owner/repo del remoto "origin". Vacío si no hay o no es de github.com.
repo_from_origin() {
  git -C "$ROOT" remote get-url origin 2>/dev/null | sed -nE \
    -e 's#/+$##' -e 's#\.git$##' \
    -e 's#^(https?|ssh)://([^/@]+@)?github\.com(:[0-9]+)?/([^/]+/[^/]+)$#\4#p' \
    -e 's#^[^/@]+@github\.com:([^/]+/[^/]+)$#\1#p'
}

ask_repo() {
  local answer
  while true; do
    printf '  Tu repo en GitHub (por ejemplo ana/vantix): '
    read -r answer || die "Cancelado: no se cambió nada."
    if valid_repo "$answer"; then REPO="$answer"; return 0; fi
    echo "  Debe tener la forma usuario/repo."
  done
}

IS_ADMIN=""
# Lee el repo con la cuenta activa. Devuelve 1 si no existe o la cuenta no puede verlo.
read_repo() {
  if ! spin "Buscando $REPO en GitHub" gh api --hostname github.com "repos/$REPO" \
      --jq '[.full_name, (.permissions.admin | tostring)] | @tsv'; then
    stop_if_offline
    return 1
  fi
  # full_name es el nombre actual aunque el repo se haya renombrado.
  REPO="$(tail -n 1 "$LOG" | cut -f 1)"
  IS_ADMIN="$(tail -n 1 "$LOG" | cut -f 2)"
}

ensure_repo() {
  local source="--repo"
  if [ -z "$REPO" ]; then REPO="$(repo_from_origin)"; source="remoto origin"; fi
  if [ -z "$REPO" ]; then
    warn "No se pudo detectar tu repo por el remoto origin"
    ask_repo
    source="indicado por ti"
  fi
  while true; do
    if ! read_repo; then
      err "$REPO no existe, o la cuenta $USER_LOGIN no puede verlo"
    elif [ "$IS_ADMIN" != "true" ]; then
      err "La cuenta $USER_LOGIN no administra $REPO"
      info "Si es el repo original, usa tu fork (Paso 0)."
    else
      ok "Repo: $REPO ($source), administrado por $USER_LOGIN"
      return 0
    fi
    echo
    if confirm "¿Usar otro repo?"; then
      ask_repo; source="indicado por ti"
    elif confirm "¿Iniciar sesión con otra cuenta de GitHub?"; then
      login || die "No se pudo iniciar sesión (ver el error arriba)."
      ok "Cuenta de GitHub: $USER_LOGIN"
    else
      echo "No se cambió nada."
      exit 1
    fi
  done
}

# Deja en VALUE cómo se presenta el repo en el token OIDC, sin el prefijo "repo:".
read_value() {
  local default immutable prefix
  if ! spin "Preguntando cómo se identifica ante AWS" gh api --hostname github.com \
      "repos/$REPO/actions/oidc/customization/sub" \
      --jq '[(.use_default | tostring), (.use_immutable_subject | tostring), (.sub_claim_prefix // "-")] | @tsv'; then
    stop_if_offline
    show_log
    die "GitHub no dijo cómo se identifica el repo (ver el error arriba)."
  fi
  default="$(tail -n 1 "$LOG" | cut -f 1)"
  immutable="$(tail -n 1 "$LOG" | cut -f 2)"
  prefix="$(tail -n 1 "$LOG" | cut -f 3)"

  if [ "$default" = "false" ]; then
    die "$REPO tiene un formato OIDC personalizado y los roles de Terraform esperan el normal. Restablécelo en GitHub y vuelve a correr este script."
  fi
  if [ "$prefix" != "-" ]; then
    VALUE="${prefix#repo:}"
  elif [ "$immutable" = "true" ]; then   # sin prefijo en la respuesta: se arma con los IDs
    spin "Leyendo los IDs del repo" gh api --hostname github.com "repos/$REPO" \
      --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"' || { show_log; die "No se pudieron leer los IDs del repo."; }
    VALUE="$(tail -n 1 "$LOG")"
  else
    VALUE="$REPO"
  fi

  if ! printf '%s\n' "$VALUE" | grep -E '^[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$' >/dev/null; then
    die "GitHub respondió un identificador inesperado: $VALUE"
  fi
  # El identificador, sin los @ID, debe ser el mismo repo.
  if [ "$(printf '%s' "$VALUE" | sed -E 's/@[0-9]+//g' | tr '[:upper:]' '[:lower:]')" != \
       "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    die "El identificador ($VALUE) no corresponde a $REPO."
  fi
  ok "Identificador ante AWS: $VALUE"
}

# --- 3. terraform.tfvars ------------------------------------------------------
# Valores de github_repo que tiene el archivo, uno por línea (puede haber ninguno o estar repetido).
tfvars_values() {
  [ -f "$1" ] || return 0
  awk '/^[ \t]*github_repo[ \t]*=/ { split($0, part, "\""); print part[2] }' "$1"
}

tfvars_ready() { [ "$(tfvars_values "$1")" = "$VALUE" ]; }

# Deja una sola línea github_repo con VALUE y conserva el resto. Guarda copia si el archivo ya existía.
write_tfvars() {
  local file="$1" dir
  dir="$(dirname "$file")"
  # Los nombres terminan en .tfvars para que .gitignore los excluya; Terraform solo carga terraform.tfvars.
  PART="$dir/nuevo.$$.tfvars"
  if [ -f "$file" ]; then
    cp -p "$file" "$dir/anterior.$(date +%Y%m%d%H%M%S).tfvars" || return 1
    cp -p "$file" "$PART" || return 1
  else
    ( umask 077 && : > "$PART" ) || return 1
  fi
  awk -v line="github_repo = \"$VALUE\"" '
    /^[ \t]*github_repo[ \t]*=/ { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }' "$([ -f "$file" ] && printf '%s' "$file" || printf /dev/null)" > "$PART" || return 1
  mv "$PART" "$file" || return 1
  PART=""
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg file current pending=0 changed=0

  for arg in "$@"; do
    case "$arg" in
      --repo=*)  REPO="${arg#*=}"; valid_repo "$REPO" || die "--repo debe tener la forma usuario/repo: $REPO" ;;
      --help|-h) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: la sesión debe quedar en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  command -v gh  >/dev/null 2>&1 || die "Falta GitHub CLI: corre primero paso1.sh."
  command -v git >/dev/null 2>&1 || die "Falta Git: corre primero paso1.sh."
  for file in "${TFVARS[@]}"; do
    [ -d "$ROOT/$(dirname "$file")" ] || die "No se encontró $(dirname "$file"): el script debe estar en pipelines/training/setup/ del repo."
  done

  LOG="$(mktemp)" || die "No se pudo crear un archivo temporal."
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  stage 1 "Tu cuenta de GitHub"
  ensure_login

  stage 2 "Tu repo"
  ensure_repo
  read_value

  stage 3 "Guardar la autorización"
  for file in "${TFVARS[@]}"; do
    if tfvars_ready "$ROOT/$file"; then ok "$file: ya está"; else pending=$((pending + 1)); fi
  done
  if [ "$pending" -eq 0 ]; then
    ok "No hay nada que cambiar"
  else
    echo "  Falta ($pending):"
    for file in "${TFVARS[@]}"; do
      if tfvars_ready "$ROOT/$file"; then continue; fi
      current="$(tfvars_values "$ROOT/$file" | paste -s -d ' ' -)"
      if [ ! -f "$ROOT/$file" ]; then echo "  - Crear $file"
      elif [ -z "$current" ];    then echo "  - Agregar github_repo a $file (lo demás no cambia; guarda una copia)"
      else                            echo "  - Cambiar github_repo en $file (lo demás no cambia; guarda una copia)"
                                      echo "      antes: $current"
      fi
      echo "      github_repo = \"$VALUE\""
    done
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
    for file in "${TFVARS[@]}"; do
      if tfvars_ready "$ROOT/$file"; then continue; fi
      if [ -n "$(tfvars_values "$ROOT/$file")" ]; then changed=1; fi
      write_tfvars "$ROOT/$file" || die "No se pudo escribir $file. Vuelve a correr este script: continúa desde aquí."
      ok "$file: guardado"
    done
  fi

  stage 4 "Comprobar"
  for file in "${TFVARS[@]}"; do
    tfvars_ready "$ROOT/$file" || die "$file no quedó con github_repo = \"$VALUE\"."
    if command -v terraform >/dev/null 2>&1; then
      if ! terraform fmt - < "$ROOT/$file" >"$LOG" 2>&1; then
        show_log
        die "$file no es un archivo válido de Terraform (ver el error arriba)."
      fi
    fi
    ok "$file: github_repo = \"$VALUE\""
  done
  if [ "$changed" -eq 1 ]; then
    warn "El valor cambió. Si ya habías levantado la infraestructura, aplícalo: make train-up y make monitoring-up"
  fi
  title "Todo listo. Puedes seguir con el Paso 5 del README."
}

main "$@"
