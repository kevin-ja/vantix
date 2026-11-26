#!/usr/bin/env bash
# Paso 2 · Credenciales de AWS (ver pipelines/training/README.md). Solo macOS.
#
# Si el perfil ya existe (solo inicia sesión si hace falta, igual que `make login`):
#   bash pipelines/training/setup/paso2.sh
#
# La primera vez (crea el perfil; lo que no se pase, lo pregunta):
#   bash pipelines/training/setup/paso2.sh \
#     --sso-start-url=https://mi-portal.awsapps.com/start \
#     --sso-region=us-east-1 \
#     --account-id=123456789012 \
#     --role-name=AdministratorAccess
#
# Opciones:
#   --sso-start-url=URL   URL del portal de acceso de AWS (IAM Identity Center)
#   --sso-region=REGION   región donde está IAM Identity Center (puede no ser us-east-1)
#   --account-id=ID       número de 12 dígitos de la member account dedicada a Vantix
#   --role-name=ROL       rol (permission set) con permisos de administrador. Por defecto: AdministratorAccess
#   --profile=NOMBRE      nombre del perfil. Por defecto: vantix
#   --help                muestra esta ayuda
#
# Ningún dato es secreto: no pide ni guarda contraseñas o llaves. El inicio de sesión ocurre en el navegador.
# Antes de cambiar algo muestra qué hará y pregunta (y/n). No modifica un perfil que ya existe, salvo su región.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

REGION="us-east-1"          # fija en los workflows
PROFILE="vantix"
SSO_START_URL=""; SSO_REGION=""; ACCOUNT_ID=""; ROLE_NAME=""
DEFAULT_ROLE="AdministratorAccess"
DOCKER_WAIT=120             # segundos
CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

# El perfil siempre se pasa explícito: otro que esté activo en la terminal no debe interferir.
unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_PAGER=""

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

LOG=""; SPIN_PID=""
cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if [ -n "$LOG" ]; then rm -f "$LOG"; fi
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

# task "qué está haciendo" "qué quedó hecho" comando… -> subpaso con ✔ o ✘ y el error exacto.
task() {
  local doing="$1" done_msg="$2"
  shift 2
  if spin "$doing" "$@"; then ok "$done_msg"; return 0; fi
  err "$doing: falló"
  show_log
  return 1
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

have() { command -v "$1" >/dev/null 2>&1; }

# --- opciones -----------------------------------------------------------------
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sso-start-url=*) SSO_START_URL="${arg#*=}" ;;
      --sso-region=*)    SSO_REGION="${arg#*=}" ;;
      --account-id=*)    ACCOUNT_ID="${arg#*=}" ;;
      --role-name=*)     ROLE_NAME="${arg#*=}" ;;
      --profile=*)       PROFILE="${arg#*=}" ;;
      --help|-h)         usage; exit 0 ;;
      *) die "Opción desconocida: $arg (usa --clave=valor; ver --help)" ;;
    esac
  done
  SSO_START_URL="$(clean_url "$SSO_START_URL")"
}

# El portal suele copiarse con "#" o "/" al final.
clean_url() { printf '%s' "$1" | sed -e 's/[#/]*$//'; }

valid() {
  local pattern
  case "$1" in
    sso-start-url) pattern='^https://[A-Za-z0-9._/-]+$' ;;
    sso-region)    pattern='^[a-z]{2}(-[a-z]+)+-[0-9]+$' ;;
    account-id)    pattern='^[0-9]{12}$' ;;
    role-name)     pattern='^[A-Za-z0-9+=,.@_-]+$' ;;
    profile)       pattern='^[A-Za-z0-9._-]+$' ;;
  esac
  printf '%s\n' "$2" | grep -qE "$pattern"
}

# Los datos pasados por opción se validan siempre, aunque el perfil ya exista.
validate_given() {
  valid profile "$PROFILE" || die "--profile no es válido: $PROFILE"
  if [ -n "$SSO_START_URL" ]; then valid sso-start-url "$SSO_START_URL" || die "--sso-start-url no es válida: $SSO_START_URL"; fi
  if [ -n "$SSO_REGION" ];    then valid sso-region    "$SSO_REGION"    || die "--sso-region no es válida: $SSO_REGION"; fi
  if [ -n "$ACCOUNT_ID" ];    then valid account-id    "$ACCOUNT_ID"    || die "--account-id debe tener 12 dígitos: $ACCOUNT_ID"; fi
  if [ -n "$ROLE_NAME" ];     then valid role-name     "$ROLE_NAME"     || die "--role-name no es válido: $ROLE_NAME"; fi
}

# ask <dato> "pregunta" [por defecto] -> deja la respuesta en ANSWER
ANSWER=""
ask() {
  while true; do
    if [ -n "$3" ]; then printf '  %s [%s]: ' "$2" "$3"; else printf '  %s: ' "$2"; fi
    read -r ANSWER || die "Cancelado: no se cambió nada."
    ANSWER="${ANSWER:-$3}"
    if [ "$1" = "sso-start-url" ]; then ANSWER="$(clean_url "$ANSWER")"; fi
    if valid "$1" "$ANSWER"; then return 0; fi
    echo "  Valor no válido, intenta de nuevo."
  done
}

ask_missing() {
  if [ -z "$SSO_START_URL" ] || [ -z "$SSO_REGION" ] || [ -z "$ACCOUNT_ID" ]; then
    title "Datos para crear el perfil"
    echo "Están en tu portal de acceso de AWS: elige la cuenta → Access keys (Claves de acceso) → IAM Identity Center."
  fi
  if [ -z "$SSO_START_URL" ]; then ask sso-start-url "URL del portal (SSO start URL)" ""; SSO_START_URL="$ANSWER"; fi
  if [ -z "$SSO_REGION" ];    then ask sso-region "Región del portal (SSO region)" ""; SSO_REGION="$ANSWER"; fi
  if [ -z "$ACCOUNT_ID" ];    then ask account-id "Número de la member account (12 dígitos)" ""; ACCOUNT_ID="$ANSWER"; fi
  if [ -z "$ROLE_NAME" ];     then ROLE_NAME="$DEFAULT_ROLE"; fi
}

# --- lectura de ~/.aws --------------------------------------------------------
profile_exists() { aws configure list-profiles 2>/dev/null | grep -xF -- "$PROFILE" >/dev/null; }
profile_get()    { aws configure get "$1" --profile "$PROFILE" 2>/dev/null; }

section_exists() {
  [ -f "$CONFIG" ] && awk -v s="[$1]" '
    { gsub(/^[ \t]+/, ""); gsub(/[ \t\r]+$/, "") }
    $0 == s { found = 1 }
    END { exit !found }' "$CONFIG"
}

# section_get <sección> <clave>: `aws configure get` no lee las secciones [sso-session …].
section_get() {
  [ -f "$CONFIG" ] || return 0
  awk -v s="[$1]" -v key="$2" '
    { gsub(/^[ \t]+/, ""); gsub(/[ \t\r]+$/, "") }
    /^\[/ { inside = ($0 == s); next }
    inside && (i = index($0, "=")) {
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      gsub(/[ \t]+$/, "", k); gsub(/^[ \t]+/, "", v)
      if (k == key) { print v; exit }
    }' "$CONFIG"
}

# same <opción> <pedido> <actual>: si se pidió un valor distinto al del perfil, se detiene sin cambiar nada.
same() {
  if [ -n "$2" ] && [ "$2" != "$3" ]; then
    die "El perfil '$PROFILE' ya existe con otro valor ($1: $3). No se cambió nada: usa otro nombre con --profile=NOMBRE."
  fi
}

# Comprueba que el perfil existente sea de SSO, esté completo y coincida con lo pedido.
check_existing_profile() {
  local session url region
  if [ -n "$(profile_get aws_access_key_id)" ]; then
    die "El perfil '$PROFILE' usa llaves fijas (IAM user). Este proyecto usa SSO: elige otro nombre con --profile=NOMBRE."
  fi
  session="$(profile_get sso_session)"
  if [ -n "$session" ]; then
    url="$(section_get "sso-session $session" sso_start_url)"
    region="$(section_get "sso-session $session" sso_region)"
  else   # formato anterior, sin sección sso-session
    url="$(profile_get sso_start_url)"
    region="$(profile_get sso_region)"
  fi
  url="$(clean_url "$url")"
  CURRENT_ACCOUNT="$(profile_get sso_account_id)"
  CURRENT_ROLE="$(profile_get sso_role_name)"
  if [ -z "$url" ] || [ -z "$region" ] || [ -z "$CURRENT_ACCOUNT" ] || [ -z "$CURRENT_ROLE" ]; then
    die "El perfil '$PROFILE' existe, pero no es de SSO o está incompleto. No se cambió nada: usa otro nombre con --profile=NOMBRE."
  fi
  same --sso-start-url "$SSO_START_URL" "$url"
  same --sso-region    "$SSO_REGION"    "$region"
  same --account-id    "$ACCOUNT_ID"    "$CURRENT_ACCOUNT"
  same --role-name     "$ROLE_NAME"     "$CURRENT_ROLE"
}

# --- acciones -----------------------------------------------------------------
session_valid() { aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; }
docker_on()     { docker info >/dev/null 2>&1; }

backup_config() {
  if [ ! -f "$CONFIG" ]; then return 0; fi
  local copy
  copy="$CONFIG.anterior.$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG" "$copy" || return 1
  echo "$copy"
}

write_sso_session() {
  mkdir -p "$(dirname "$CONFIG")" || return 1
  printf '\n[sso-session %s]\nsso_start_url = %s\nsso_region = %s\nsso_registration_scopes = sso:account:access\n' \
    "$PROFILE" "$SSO_START_URL" "$SSO_REGION" >> "$CONFIG" || return 1
  chmod 600 "$CONFIG"
}

# put <clave> <valor> "descripción"
put() { task "Guardando $3" "$3: $2" aws configure set "$1" "$2" --profile "$PROFILE"; }

create_profile() {
  if section_exists "sso-session $PROFILE"; then
    ok "Portal SSO: ya estaba guardado"
  else
    task "Guardando el portal SSO" "Portal SSO: $SSO_START_URL ($SSO_REGION)" write_sso_session || return 1
  fi
  put sso_session    "$PROFILE"    "Sesión SSO"         || return 1
  put sso_account_id "$ACCOUNT_ID" "Cuenta"             || return 1
  put sso_role_name  "$ROLE_NAME"  "Rol"                || return 1
  put region         "$REGION"     "Región"             || return 1
  put output         json          "Formato de salida"
}

login() {
  info "Se abrirá tu navegador: inicia sesión y autoriza el acceso."
  info "Esta terminal espera hasta que termines (Ctrl+C cancela)."
  echo
  aws sso login --profile "$PROFILE" || return 1
  echo
}

start_docker() {
  local waited=0
  open -a Docker || return 1
  while ! docker_on; do
    if [ "$waited" -ge "$DOCKER_WAIT" ]; then echo "Docker no respondió en $DOCKER_WAIT s"; return 1; fi
    sleep 3
    waited=$((waited + 3))
  done
}

# Comprueba a qué cuenta se entró y con qué identidad.
verify_identity() {
  local identity account arn management
  if ! spin "Preguntando a AWS quién eres" \
      aws sts get-caller-identity --profile "$PROFILE" --query '[Account,Arn]' --output text; then
    show_log
    return 1
  fi
  identity="$(tail -n 1 "$LOG")"
  account="$(printf '%s' "$identity" | awk '{print $1}')"
  arn="$(printf '%s' "$identity" | awk '{print $2}')"

  if [ "$account" != "$CURRENT_ACCOUNT" ]; then
    err "Se entró a la cuenta $account y el perfil es de la $CURRENT_ACCOUNT."
    return 1
  fi
  case "$arn" in
    *:assumed-role/AWSReservedSSO_*) ok "Identidad: SSO, rol $CURRENT_ROLE" ;;
    *) err "La identidad no es de SSO: $arn"; return 1 ;;
  esac
  ok "Cuenta de AWS: $account"
  if [ "$CURRENT_ROLE" != "$DEFAULT_ROLE" ]; then
    warn "El rol no es $DEFAULT_ROLE: confirma que tiene permisos de administrador (Terraform crea roles de IAM)."
  fi

  if spin "Comprobando el tipo de cuenta" aws organizations describe-organization --profile "$PROFILE" \
      --region us-east-1 --query Organization.MasterAccountId --output text; then
    management="$(tail -n 1 "$LOG")"
    if [ "$management" = "$account" ]; then
      warn "Es la management account de la organización: se recomienda una member account dedicada a Vantix."
    else
      ok "Es una member account"
    fi
  else
    case "$(cat "$LOG")" in
      *AWSOrganizationsNotInUse*) warn "La cuenta no pertenece a una AWS Organization: se recomienda una member account." ;;
      *) warn "No se pudo comprobar si es una member account (falta permiso de lectura de la organización)." ;;
    esac
  fi
}

# --- flujo --------------------------------------------------------------------
CURRENT_ACCOUNT=""; CURRENT_ROLE=""

main() {
  local do_profile=0 do_region=0 do_login=0 do_docker=0 total=0 i=0 region

  parse_args "$@"
  if [ "$(uname -s)" != "Darwin" ]; then die "Este script es solo para macOS. En otro sistema, sigue a mano el Paso 2 del README."; fi
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: las credenciales deben quedar en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  have aws    || die "Falta AWS CLI: corre primero paso1.sh."
  have docker || die "Falta Docker: corre primero paso1.sh."
  aws --version 2>&1 | grep '^aws-cli/2' >/dev/null || die "Se necesita AWS CLI 2: corre primero paso1.sh."
  validate_given

  LOG="$(mktemp)" || die "No se pudo crear un archivo temporal."
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  stage 1 "Revisar qué tienes"
  if spin "Buscando el perfil '$PROFILE'" profile_exists; then
    check_existing_profile
    ok "Perfil '$PROFILE': existe (cuenta $CURRENT_ACCOUNT, rol $CURRENT_ROLE)"
    region="$(profile_get region)"
    if [ "$region" = "$REGION" ]; then
      ok "Región: $REGION"
    else
      warn "Región: ${region:-sin definir} (se necesita $REGION)"; do_region=1
    fi
    if spin "Comprobando la sesión de AWS" session_valid; then ok "Sesión: iniciada"; else err "Sesión: vencida o sin iniciar"; do_login=1; fi
  else
    err "Perfil '$PROFILE': no existe"
    do_profile=1; do_login=1
  fi
  if spin "Comprobando Docker" docker_on; then ok "Docker: encendido"; else err "Docker: apagado"; do_docker=1; fi
  if [ -n "$AWS_ACCESS_KEY_ID" ]; then
    warn "Tu terminal tiene AWS_ACCESS_KEY_ID definida y puede interferir. Quítala: unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"
  fi

  if [ "$do_profile" -eq 1 ]; then
    ask_missing
    # La sección sso-session puede existir aunque el perfil no: se reutiliza solo si coincide.
    if section_exists "sso-session $PROFILE"; then
      if [ "$(clean_url "$(section_get "sso-session $PROFILE" sso_start_url)")" != "$SSO_START_URL" ] ||
         [ "$(section_get "sso-session $PROFILE" sso_region)" != "$SSO_REGION" ]; then
        die "Ya existe [sso-session $PROFILE] con otros valores en $CONFIG. No se cambió nada: usa otro nombre con --profile=NOMBRE."
      fi
    fi
  fi

  total=$((do_profile + do_region + do_login + do_docker))
  stage 2 "Confirmar los cambios"
  if [ "$total" -eq 0 ]; then
    ok "No hay nada que cambiar"
  else
    echo "  Falta ($total):"
    if [ "$do_profile" -eq 1 ]; then
      echo "  - Crear el perfil '$PROFILE' en $CONFIG"
      echo "      portal: $SSO_START_URL ($SSO_REGION)"
      echo "      cuenta: $ACCOUNT_ID · rol: $ROLE_NAME · región: $REGION"
    fi
    if [ "$do_region" -eq 1 ]; then echo "  - Cambiar la región del perfil '$PROFILE' a $REGION"; fi
    if [ "$do_login" -eq 1 ];  then echo "  - Iniciar sesión en AWS (se abre el navegador)"; fi
    if [ "$do_docker" -eq 1 ]; then echo "  - Encender Docker Desktop"; fi
    echo
    if ! confirm "¿Proceder?"; then echo "No se cambió nada."; exit 1; fi
  fi

  stage 3 "Configurar"
  if [ "$total" -eq 0 ]; then ok "Nada que hacer"; fi
  if [ "$((do_profile + do_region))" -gt 0 ]; then
    if ! spin "Copiando $CONFIG" backup_config; then
      show_log
      die "No se pudo hacer la copia de seguridad de $CONFIG: no se cambió nada."
    fi
    if [ -s "$LOG" ]; then ok "Copia de seguridad: $(cat "$LOG")"; fi
  fi
  if [ "$do_profile" -eq 1 ]; then
    i=$((i + 1)); title "[$i/$total] Crear el perfil"
    create_profile || die "No se pudo crear el perfil en $CONFIG."
    CURRENT_ACCOUNT="$ACCOUNT_ID"; CURRENT_ROLE="$ROLE_NAME"
    ok "Perfil '$PROFILE' creado"
  fi
  if [ "$do_region" -eq 1 ]; then
    i=$((i + 1)); title "[$i/$total] Cambiar la región"
    put region "$REGION" "Región" || die "No se pudo cambiar la región."
  fi
  if [ "$do_login" -eq 1 ]; then
    i=$((i + 1)); title "[$i/$total] Iniciar sesión"
    login || die "No se pudo iniciar sesión (ver el error arriba). Vuelve a correr este script para reintentar."
    ok "Sesión iniciada"
  fi
  if [ "$do_docker" -eq 1 ]; then
    i=$((i + 1)); title "[$i/$total] Encender Docker"
    task "Esperando a que Docker responda (hasta $DOCKER_WAIT s)" "Docker encendido" start_docker \
      || die "Abre Docker Desktop, revisa si pide algo y vuelve a correr este script."
  fi

  stage 4 "Comprobar"
  verify_identity || die "AWS no respondió como se esperaba (ver el error arriba)."
  if spin "Comprobando Docker" docker_on; then ok "Docker: encendido"; else die "Docker dejó de responder: ábrelo y vuelve a correr este script."; fi
  title "Todo listo. Puedes seguir con el siguiente paso del README."
  if [ "$PROFILE" != "vantix" ]; then
    warn "Tu perfil no se llama vantix: agrégalo a cada comando, p. ej. make mlflow-status AWS_PROFILE=$PROFILE"
  fi
}

main "$@"
