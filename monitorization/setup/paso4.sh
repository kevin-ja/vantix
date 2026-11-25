#!/usr/bin/env bash
# Paso 4 · Conectar GitHub con el monitoreo (ver monitorization/README.md).
#
#   bash monitorization/setup/paso4.sh
#   --repo=ana/vantix    si tu repo no es el del remoto origin
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Carga en tu repo las 3 variables que usan los workflows del monitoreo. Van a nivel de repo, no en `production`: esos
# workflows no piden aprobación porque no tocan el modelo ni los scores. No son secretos.
# No necesita credenciales: usa tu sesión de GitHub y tu perfil de AWS.
# Muestra qué cambiará y pregunta (y/n). Solo toca esas 3 variables. Se puede correr varias veces.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
REPO=""
export GH_PAGER="cat"

# Variable de GitHub | carpeta de Terraform | output | forma que debe tener el valor
SPECS=(
  "GH_MONITORING_CI_ROLE_ARN|monitorization/infra|github_ci_role_arn|^arn:aws:iam::ACCOUNT:role/[A-Za-z0-9+=,.@_/-]+$"
  "GH_MONITORING_RUN_ROLE_ARN|monitorization/infra|github_run_role_arn|^arn:aws:iam::ACCOUNT:role/[A-Za-z0-9+=,.@_/-]+$"
  "MONITORING_GRAFANA_URL|monitorization/infra|grafana_url|^https://[A-Za-z0-9.-]+$"
)

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

LOG=""; SPIN_PID=""; WORK=""
cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
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

valid_repo() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' >/dev/null; }
valid_profile() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9._-]+$' >/dev/null; }

# --- AWS ----------------------------------------------------------------------
ACCOUNT_ID=""; STATE_BUCKET=""

# El perfil manda: las llaves u otro perfil activos en la terminal podrían apuntar a otra cuenta.
use_profile() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
  export AWS_PROFILE="$PROFILE" AWS_PAGER=""
}

whoami_aws() { aws sts get-caller-identity --profile "$PROFILE" --query Account --output text; }

check_aws() {
  env -u AWS_PROFILE aws configure list-profiles 2>/dev/null | grep -xF -- "$PROFILE" >/dev/null \
    || die "No existe el perfil de AWS '$PROFILE': corre primero pipelines/training/setup/paso2.sh."
  if ! spin "Comprobando la sesión de AWS" whoami_aws; then
    err "Sesión de AWS: vencida o sin iniciar"
    confirm "¿Iniciar sesión en AWS? (se abre el navegador)" || die "Sin sesión de AWS no se puede continuar."
    aws sso login --profile "$PROFILE" || die "No se pudo iniciar sesión (ver el error arriba). Vuelve a correr pipelines/training/setup/paso2.sh."
    spin "Comprobando la sesión de AWS" whoami_aws || { show_log; die "AWS no respondió."; }
  fi
  ACCOUNT_ID="$(tail -n 1 "$LOG")"
  printf '%s\n' "$ACCOUNT_ID" | grep -E '^[0-9]{12}$' >/dev/null || die "AWS respondió una cuenta inesperada: $ACCOUNT_ID"
  STATE_BUCKET="vantix-$ACCOUNT_ID-tfstate"
  ok "Cuenta de AWS: $ACCOUNT_ID (perfil $PROFILE)"
}

start_checks() {
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: tu sesión de AWS está en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  command -v aws >/dev/null 2>&1 || die "Falta AWS CLI: corre primero pipelines/training/setup/paso1.sh."
  WORK="$(mktemp -d)" || die "No se pudo crear una carpeta temporal."
  LOG="$WORK/log"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  use_profile
}

check_state_bucket() {
  spin "Buscando el bucket del estado" aws s3api head-bucket --bucket "$STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    || { show_log; die "No existe (o no es tuyo) el bucket $STATE_BUCKET: corre primero pipelines/training/setup/paso7.sh."; }
  ok "Bucket del estado: $STATE_BUCKET"
}

# --- Terraform ----------------------------------------------------------------
TERRAFORM_VERSION="1.15.8"   # exacta: la exige mlflow_server/infra/versions.tf

check_terraform() {
  local version
  if [ -x "$HOME/.local/bin/terraform" ]; then export PATH="$HOME/.local/bin:$PATH"; fi   # donde lo instala pipelines/training/setup/paso1.sh
  command -v terraform >/dev/null 2>&1 || die "Falta Terraform: corre primero pipelines/training/setup/paso1.sh."
  # Variables de la terminal que cambiarían lo que hace Terraform.
  unset TF_WORKSPACE TF_DATA_DIR TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_output
  export TF_IN_AUTOMATION=1
  version="$(terraform version | awk 'NR == 1 {sub(/^v/, "", $2); print $2}')"
  [ "$version" = "$TERRAFORM_VERSION" ] || die "Terraform es $version y se necesita $TERRAFORM_VERSION: corre primero pipelines/training/setup/paso1.sh."
  ok "Terraform: $version"
}

tf() { local dir="$1"; shift; terraform -chdir="$ROOT/$dir" "$@"; }

# tf_init <módulo> <clave del estado>
tf_init() {
  spin "Preparando Terraform en $1" tf "$1" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$2" -backend-config="region=$REGION" \
    -backend-config="profile=$PROFILE" -backend-config="use_lockfile=true" \
    || { show_log; die "No se pudo preparar Terraform en $1 (ver el error arriba)."; }
  ok "$1: Terraform preparado"
}

# --- GitHub -------------------------------------------------------------------
USER_LOGIN=""; USER_ID=""
# Si el error no es de autenticación, iniciar sesión no lo arregla: se detiene y lo muestra.
stop_if_offline() {
  if grep -iE 'error connecting|could not resolve|no such host|timeout|timed out|HTTP 5[0-9][0-9]|rate limit' "$LOG" >/dev/null; then
    show_log
    die "GitHub no respondió. Revisa tu conexión y vuelve a correr este script."
  fi
}


github() { gh api --hostname github.com "$@"; }

check_account() {
  if ! spin "Comprobando tu sesión de GitHub" github user --jq '[.login, (.id | tostring)] | @tsv'; then
    stop_if_offline
    die "No hay sesión de GitHub: corre primero pipelines/training/setup/paso4.sh."
  fi
  USER_LOGIN="$(tail -n 1 "$LOG" | cut -f 1)"
  USER_ID="$(tail -n 1 "$LOG" | cut -f 2)"
  printf '%s\n' "$USER_ID" | grep -E '^[0-9]+$' >/dev/null || die "GitHub respondió una cuenta inesperada."
  ok "Cuenta de GitHub: $USER_LOGIN"
}

# owner/repo del remoto "origin". Vacío si no hay o no es de github.com.
repo_from_origin() {
  git -C "$ROOT" remote get-url origin 2>/dev/null | sed -nE \
    -e 's#/+$##' -e 's#\.git$##' \
    -e 's#^(https?|ssh)://([^/@]+@)?github\.com(:[0-9]+)?/([^/]+/[^/]+)$#\4#p' \
    -e 's#^[^/@]+@github\.com:([^/]+/[^/]+)$#\1#p'
}

check_repo() {
  local admin
  if [ -z "$REPO" ]; then REPO="$(repo_from_origin)"; fi
  if [ -z "$REPO" ]; then die "No se pudo detectar tu repo por el remoto origin: indícalo con --repo=usuario/repo."; fi
  if ! spin "Buscando $REPO en GitHub" github "repos/$REPO" --jq '[.full_name, (.permissions.admin | tostring)] | @tsv'; then
    stop_if_offline
    die "$REPO no existe, o la cuenta $USER_LOGIN no puede verlo. Indica tu repo con --repo=usuario/repo."
  fi
  REPO="$(tail -n 1 "$LOG" | cut -f 1)"
  admin="$(tail -n 1 "$LOG" | cut -f 2)"
  if [ "$admin" != "true" ]; then
    die "La cuenta $USER_LOGIN no administra $REPO. Usa tu fork (--repo=usuario/repo) o cambia de cuenta con pipelines/training/setup/paso4.sh."
  fi
  ok "Repo: $REPO"
}

# Los roles de AWS deben confiar en este repo: si no, las variables quedarían bien y los workflows fallarían igual.
check_trust() {
  local prefix trusted role
  role="$(value_of GH_MONITORING_RUN_ROLE_ARN)"
  spin "Leyendo cómo se identifica el repo" github "repos/$REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix // "-"' \
    || { stop_if_offline; show_log; die "GitHub no dijo cómo se identifica el repo (ver el error arriba)."; }
  prefix="$(tail -n 1 "$LOG")"
  if [ "$prefix" = "-" ]; then prefix="repo:$REPO"; fi
  spin "Comprobando en quién confía AWS" aws iam get-role --role-name "${role##*/}" \
    --query 'Role.AssumeRolePolicyDocument' --output json \
    || { show_log; die "No se pudo leer el rol ${role##*/} (ver el error arriba): corre primero monitorization/setup/paso3.sh."; }
  trusted="$(sed -nE 's/.*"(repo:[^"]*):ref:refs\/heads\/main".*/\1/p' "$LOG" | head -n 1)"
  if [ "$trusted" != "$prefix" ]; then
    err "AWS confía en '${trusted:-nadie}' y tu repo se identifica como '$prefix'"
    die "Corre pipelines/training/setup/paso4.sh y después monitorization/setup/paso3.sh, y vuelve a correr este script. No se cambió nada."
  fi
  ok "AWS confía en tu repo: ${prefix#repo:}"
}

# --- variables ----------------------------------------------------------------
# $WORK/values: lo que debe haber. $WORK/current: lo que hay en GitHub. Una por línea: NOMBRE<tab>valor.
lookup()   { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
value_of() { lookup "$WORK/values" "$1"; }
current()  { lookup "$WORK/current" "$1"; }

read_values() {
  local spec name module output pattern value
  : > "$WORK/values"
  for spec in "${SPECS[@]}"; do
    IFS='|' read -r name module output pattern <<EOF
$spec
EOF
    pattern="$(printf '%s' "$pattern" | sed "s/ACCOUNT/$ACCOUNT_ID/")"
    spin "Leyendo $output" tf "$module" output -raw "$output" \
      || { show_log; die "La infraestructura no está levantada o está incompleta (falta $output): corre primero monitorization/setup/paso3.sh."; }
    value="$(tail -n 1 "$LOG")"
    # Sin infraestructura, `output` puede devolver un aviso en vez del valor.
    printf '%s\n' "$value" | grep -E -- "$pattern" >/dev/null \
      || die "El valor de $output no es el esperado para la cuenta $ACCOUNT_ID. Corre primero monitorization/setup/paso3.sh. No se cambió nada."
    printf '%s\t%s\n' "$name" "$value" >> "$WORK/values"
  done
  ok "Valores de la infraestructura: ${#SPECS[@]} leídos"
}

read_current() {
  if ! spin "Leyendo las variables de GitHub" gh variable list -R "github.com/$REPO" \
      --json name,value --jq '.[] | [.name, .value] | @tsv'; then
    stop_if_offline
    show_log
    die "No se pudieron leer las variables (ver el error arriba)."
  fi
  cp "$LOG" "$WORK/current"
}

# Deja en PENDING los nombres que faltan o tienen otro valor, y muestra el estado de cada una.
PENDING=()
compare() {
  local spec name
  PENDING=()
  for spec in "${SPECS[@]}"; do
    name="${spec%%|*}"
    if [ "$(current "$name")" = "$(value_of "$name")" ]; then
      ok "$name = $(value_of "$name")"
    elif [ -z "$(current "$name")" ]; then
      err "$name: falta"
      PENDING+=("$name")
    else
      err "$name: tiene otro valor"
      PENDING+=("$name")
    fi
  done
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg name i=0
  for arg in "$@"; do
    case "$arg" in
      --repo=*)    REPO="${arg#*=}";    valid_repo "$REPO"       || die "--repo debe tener la forma usuario/repo: $REPO" ;;
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  command -v gh  >/dev/null 2>&1 || die "Falta GitHub CLI: corre primero pipelines/training/setup/paso1.sh."
  command -v git >/dev/null 2>&1 || die "Falta Git: corre primero pipelines/training/setup/paso1.sh."
  [ -d "$ROOT/monitorization/infra" ] || die "No se encontró monitorization/infra: el script debe estar en monitorization/setup/ del repo."

  stage 1 "Revisar qué tienes"
  check_account
  check_repo
  check_aws
  check_state_bucket
  check_terraform
  tf_init monitorization/infra monitorization/terraform.tfstate
  read_values
  check_trust
  read_current
  compare

  stage 2 "Confirmar los cambios"
  if [ ${#PENDING[@]} -eq 0 ]; then
    ok "No hay nada que cambiar"
  else
    echo "  En las variables del repo $REPO (${#PENDING[@]}):"
    for name in "${PENDING[@]}"; do
      if [ -z "$(current "$name")" ]; then
        echo "  - Crear $name"
      else
        echo "  - Cambiar $name"
        echo "      antes: $(current "$name")"
      fi
      echo "      valor: $(value_of "$name")"
    done
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
  fi

  stage 3 "Configurar"
  if [ ${#PENDING[@]} -eq 0 ]; then ok "Nada que hacer"; fi
  for name in "${PENDING[@]}"; do
    i=$((i + 1))
    task "[$i/${#PENDING[@]}] Guardando $name" "[$i/${#PENDING[@]}] $name guardada" \
      gh variable set "$name" -R "github.com/$REPO" --body "$(value_of "$name")" \
      || die "GitHub no aceptó $name (ver el error arriba). Vuelve a correr este script: continúa desde aquí."
  done

  stage 4 "Comprobar"
  read_current
  compare
  [ ${#PENDING[@]} -eq 0 ] || die "Quedaron variables sin el valor esperado. Vuelve a correr este script."
  title "Todo listo. Ya puedes construir el benchmark: GitHub → Actions → run_monitoring_manual."
}

main "$@"
