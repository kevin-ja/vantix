# Paso: Sesión de AWS y Docker
#
# Crea el perfil de AWS con los datos de .env si no existe, inicia sesión en el navegador y enciende Docker.
# No modifica un perfil que ya existe, salvo su región. Ningún dato es secreto.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

DEFAULT_ROLE="AdministratorAccess"
DOCKER_WAIT=120             # segundos
CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

# --- lectura de ~/.aws --------------------------------------------------------
profile_get() { aws configure get "$1" --profile "$PROFILE" 2>/dev/null; }

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

clean_url() { printf '%s' "$1" | sed -e 's/[#/]*$//'; }

# same <clave de .env> <valor del perfil>: si el perfil tiene otro valor, se detiene sin cambiar nada.
same() {
  [ "${!1}" = "$2" ] \
    || die "El perfil '$PROFILE' ya existe con otro valor ($1: $2; en .env: ${!1}). No se cambió nada: corrige .env o usa otro PROFILE."
}

# Comprueba que el perfil existente sea de SSO, esté completo y coincida con .env.
check_existing_profile() {
  local session url region account role
  if [ -n "$(profile_get aws_access_key_id)" ]; then
    die "El perfil '$PROFILE' usa llaves fijas (IAM user). Este proyecto usa SSO: elige otro PROFILE en .env."
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
  account="$(profile_get sso_account_id)"
  role="$(profile_get sso_role_name)"
  if [ -z "$url" ] || [ -z "$region" ] || [ -z "$account" ] || [ -z "$role" ]; then
    die "El perfil '$PROFILE' existe, pero no es de SSO o está incompleto. No se cambió nada: usa otro PROFILE en .env."
  fi
  same SSO_START_URL "$url"
  same SSO_REGION    "$region"
  same ACCOUNT_ID    "$account"
  same ROLE_NAME     "$role"
}

session_valid() { aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; }
docker_on()     { docker info >/dev/null 2>&1; }

# Comprueba a qué cuenta se entró y con qué identidad.
verify_identity() {
  local account arn management
  spin "Preguntando a AWS quién eres" aws sts get-caller-identity --profile "$PROFILE" --query '[Account,Arn]' --output text \
    || { show_log; die "AWS no respondió."; }
  account="$(tail -n 1 "$LOG" | awk '{print $1}')"
  arn="$(tail -n 1 "$LOG" | awk '{print $2}')"
  [ "$account" = "$ACCOUNT_ID" ] || die "Se entró a la cuenta $account y .env dice ACCOUNT_ID=$ACCOUNT_ID. No se cambió nada."
  case "$arn" in
    *:assumed-role/AWSReservedSSO_*) ok "Identidad: SSO, rol $ROLE_NAME" ;;
    *) die "La identidad no es de SSO: $arn" ;;
  esac
  ok "Cuenta de AWS: $account"
  if [ "$ROLE_NAME" != "$DEFAULT_ROLE" ]; then
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

DO_PROFILE=0; DO_REGION=0; DO_LOGIN=0; DO_DOCKER=0
review() {
  DO_PROFILE=0; DO_REGION=0; DO_LOGIN=0; DO_DOCKER=0
  # Con AWS_PROFILE apuntando a un perfil que aún no existe, el propio `aws configure` falla.
  unset AWS_PROFILE
  have aws    || die "Falta AWS CLI."
  have docker || die "Falta Docker."
  if spin "Buscando el perfil '$PROFILE'" profile_exists; then
    check_existing_profile
    ok "Perfil '$PROFILE': existe y coincide con .env"
    if [ "$(profile_get region)" = "$REGION" ]; then
      ok "Región: $REGION"
    else
      todo "Región del perfil: no es $REGION"; DO_REGION=1
    fi
    if spin "Comprobando la sesión de AWS" session_valid; then
      verify_identity
    else
      todo "Sesión de AWS: vencida o sin iniciar"; DO_LOGIN=1
    fi
  else
    todo "Perfil '$PROFILE': no existe"
    DO_PROFILE=1; DO_LOGIN=1
    # La sección sso-session puede existir aunque el perfil no: se reutiliza solo si coincide.
    if section_exists "sso-session $PROFILE"; then
      if [ "$(clean_url "$(section_get "sso-session $PROFILE" sso_start_url)")" != "$SSO_START_URL" ] ||
         [ "$(section_get "sso-session $PROFILE" sso_region)" != "$SSO_REGION" ]; then
        die "Ya existe [sso-session $PROFILE] con otros valores en $CONFIG. No se cambió nada: usa otro PROFILE en .env."
      fi
    fi
  fi
  if spin "Comprobando Docker" docker_on; then ok "Docker: encendido"; else todo "Docker: apagado"; DO_DOCKER=1; fi
}

# --- acciones -----------------------------------------------------------------
backup_config() {
  local copy
  if [ ! -f "$CONFIG" ]; then return 0; fi
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

start_docker() {
  local start=$SECONDS
  open -a Docker || return 1
  while ! docker_on; do
    if [ $((SECONDS - start)) -ge "$DOCKER_WAIT" ]; then echo "Docker no respondió en $DOCKER_WAIT s"; return 1; fi
    sleep 3
  done
}

apply() {
  if [ "$((DO_PROFILE + DO_REGION))" -gt 0 ]; then
    spin "Copiando $CONFIG" backup_config || { show_log; die "No se pudo copiar $CONFIG: no se cambió nada."; }
    if [ -s "$LOG" ]; then ok "Copia de seguridad: $(cat "$LOG")"; fi
  fi
  if [ "$DO_PROFILE" -eq 1 ]; then create_profile || die "No se pudo crear el perfil en $CONFIG."; fi
  if [ "$DO_REGION" -eq 1 ]; then put region "$REGION" "Región" || die "No se pudo cambiar la región."; fi
  if [ "$DO_LOGIN" -eq 1 ]; then
    info "Se abrirá tu navegador: inicia sesión en AWS y autoriza el acceso."
    info "Esta terminal espera hasta que termines (Ctrl+C cancela)."
    echo
    aws sso login --profile "$PROFILE" || die "No se pudo iniciar sesión (ver el error arriba)."
    echo
    ok "Sesión iniciada"
  fi
  if [ "$DO_DOCKER" -eq 1 ]; then
    [ "$(uname -s)" = "Darwin" ] || die "Enciende Docker y vuelve a correr: $SETUP_COMMAND"
    info "Encendiendo Docker Desktop"
    task "Esperando a que Docker responda (hasta $DOCKER_WAIT s)" "Docker encendido" start_docker \
      || die "Abre Docker Desktop, revisa si pide algo y vuelve a correr: $SETUP_COMMAND"
  fi
}

run_step
