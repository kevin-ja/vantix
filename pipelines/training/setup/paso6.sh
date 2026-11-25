#!/usr/bin/env bash
# Paso 6 · Crear el environment `production` y comprobar la cuota de cómputo de AWS SageMaker
# (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso6.sh
#
# No necesita datos: usa tu cuenta de GitHub (paso4.sh), tu perfil de AWS (paso2.sh) y el remoto "origin".
#   --repo=ana/vantix    si tu repo no es el del remoto origin
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# GitHub: crea el environment con tu cuenta como aprobador. Si ya existe, corrige solo lo que falte y conserva lo
#         demás (otros aprobadores, tiempo de espera, ramas permitidas).
# AWS:    comprueba la cuota de ml.t3.xlarge en Processing jobs. Solo si es menor que 1 ofrece pedir el aumento.
# Pregunta (y/n) por separado antes de cada cambio. Se puede correr varias veces.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
ENVIRONMENT="production"     # fijo: lo exigen los workflows y los roles de AWS
REGION="us-east-1"           # fija en los workflows
QUOTA_NAME="ml.t3.xlarge for processing job usage"
QUOTA_MIN=1                  # Prepare y Train corren uno después del otro, cada uno en una máquina
REPO=""
PROFILE="vantix"

# El perfil siempre se pasa explícito: otro que esté activo en la terminal no debe interferir.
unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_PAGER="" GH_PAGER="cat"

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

LOG=""; SPIN_PID=""; BODY=""
cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if [ -n "$LOG" ]; then rm -f "$LOG"; fi
  if [ -n "$BODY" ]; then rm -f "$BODY"; fi
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

valid_profile() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9._-]+$' >/dev/null; }

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
    die "No hay sesión de GitHub: corre primero paso4.sh."
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
    die "La cuenta $USER_LOGIN no administra $REPO. Usa tu fork (--repo=usuario/repo) o cambia de cuenta con paso4.sh."
  fi
  ok "Repo: $REPO"
}

# Lee el environment. Deja en ENV_STATE: falta | corregir | ok | desconocido.
ENV_STATE=""; ENV_REVIEWERS=""; ENV_ME=""; ENV_SELF=""; ENV_WAIT=""; ENV_BRANCHES=""
read_environment() {
  local jq name
  ENV_STATE="desconocido"
  jq='[.name,
       ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | (.reviewer.login // .reviewer.slug)] | join(", ") | if . == "" then "-" else . end),
       ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | select(.type == "User" and .reviewer.id == '"$USER_ID"')] | length > 0 | tostring),
       ([.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review // false] | any | tostring),
       ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer] | add // 0 | tostring),
       (.deployment_branch_policy != null | tostring)] | @tsv'
  if ! spin "Leyendo el environment $ENVIRONMENT" github "repos/$REPO/environments/$ENVIRONMENT" --jq "$jq"; then
    stop_if_offline
    if grep 'HTTP 404' "$LOG" >/dev/null; then ENV_STATE="falta"; return 0; fi
    show_log
    return 1
  fi
  name="$(tail -n 1 "$LOG" | cut -f 1)"
  ENV_REVIEWERS="$(tail -n 1 "$LOG" | cut -f 2)"
  ENV_ME="$(tail -n 1 "$LOG" | cut -f 3)"
  ENV_SELF="$(tail -n 1 "$LOG" | cut -f 4)"
  ENV_WAIT="$(tail -n 1 "$LOG" | cut -f 5)"
  ENV_BRANCHES="$(tail -n 1 "$LOG" | cut -f 6)"
  if [ "$name" != "$ENVIRONMENT" ]; then
    err "El environment se llama '$name' y debe llamarse '$ENVIRONMENT' (minúsculas): bórralo en GitHub y vuelve a correr este script."
    return 1
  fi
  if [ "$ENV_ME" = "true" ] && [ "$ENV_SELF" = "false" ]; then ENV_STATE="ok"; else ENV_STATE="corregir"; fi
}

print_environment() {
  case "$ENV_STATE" in
    falta)    err "Environment $ENVIRONMENT: no existe" ;;
    ok)       ok "Environment $ENVIRONMENT: existe (aprobadores: $ENV_REVIEWERS)" ;;
    corregir)
      err "Environment $ENVIRONMENT: existe, pero hay que corregirlo"
      if [ "$ENV_ME" != "true" ];    then info "$USER_LOGIN no es aprobador (hoy: $ENV_REVIEWERS)"; fi
      if [ "$ENV_SELF" != "false" ]; then info "Prevent self-review está marcado: no podrías aprobar tus propias corridas"; fi ;;
  esac
  if [ "$ENV_STATE" = "ok" ] || [ "$ENV_STATE" = "corregir" ]; then
    if [ "$ENV_WAIT" != "0" ];       then warn "Cada corrida espera además $ENV_WAIT min (wait timer)"; fi
    if [ "$ENV_BRANCHES" = "true" ]; then warn "Solo acepta ciertas ramas: comprueba en GitHub que main esté permitida"; fi
  fi
}

# La API reemplaza toda la configuración: si el environment existe, se parte de la actual para no perder nada.
save_environment() {
  local jq
  if [ "$ENV_STATE" = "falta" ]; then
    printf '{"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}]}\n' "$USER_ID" > "$BODY" || return 1
  else
    jq='{wait_timer: ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer] | add // 0),
         prevent_self_review: false,
         reviewers: ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | {type, id: .reviewer.id}]
                     + [{type: "User", id: '"$USER_ID"'}] | unique),
         deployment_branch_policy: (.deployment_branch_policy
           | if . == null then null else {protected_branches, custom_branch_policies} end)}'
    github "repos/$REPO/environments/$ENVIRONMENT" --jq "$jq" > "$BODY" || return 1
  fi
  github --method PUT "repos/$REPO/environments/$ENVIRONMENT" --input "$BODY" --silent
}

# --- AWS ----------------------------------------------------------------------
quotas() { aws service-quotas "$@" --profile "$PROFILE" --region "$REGION" --output text; }

check_aws() {
  aws configure list-profiles 2>/dev/null | grep -xF -- "$PROFILE" >/dev/null \
    || die "No existe el perfil de AWS '$PROFILE': corre primero paso2.sh."
  if ! spin "Comprobando la sesión de AWS" aws sts get-caller-identity --profile "$PROFILE" --query Account --output text; then
    err "Sesión de AWS: vencida o sin iniciar"
    confirm "¿Iniciar sesión en AWS? (se abre el navegador)" || die "Sin sesión de AWS no se puede comprobar la cuota."
    aws sso login --profile "$PROFILE" || die "No se pudo iniciar sesión (ver el error arriba). Vuelve a correr paso2.sh."
    spin "Comprobando la sesión de AWS" aws sts get-caller-identity --profile "$PROFILE" --query Account --output text \
      || { show_log; die "AWS no respondió."; }
  fi
  ok "Cuenta de AWS: $(tail -n 1 "$LOG")"
}

QUOTA_CODE=""; QUOTA=""; QUOTA_STATE=""; QUOTA_REQUEST=""
# Deja en QUOTA_STATE: ok | baja | pedida.
read_quota() {
  local query="Quotas[?QuotaName=='$QUOTA_NAME'].[QuotaCode,Value]"
  QUOTA_CODE=""
  spin "Leyendo la cuota de cómputo de SageMaker" quotas list-service-quotas --service-code sagemaker --query "$query" \
    || { show_log; return 1; }
  QUOTA_CODE="$(awk '/^L-/ {print $1; exit}' "$LOG")"
  if [ -z "$QUOTA_CODE" ]; then   # sin valor propio en la cuenta: rige el que AWS da por defecto
    spin "Leyendo la cuota por defecto" quotas list-aws-default-service-quotas --service-code sagemaker --query "$query" \
      || { show_log; return 1; }
    QUOTA_CODE="$(awk '/^L-/ {print $1; exit}' "$LOG")"
  fi
  QUOTA="$(awk '/^L-/ {print $2; exit}' "$LOG")"
  if [ -z "$QUOTA_CODE" ] || ! printf '%s\n' "$QUOTA" | grep -E '^[0-9]+(\.[0-9]+)?$' >/dev/null; then
    err "AWS no devolvió la cuota '$QUOTA_NAME'."
    return 1
  fi
  if awk -v q="$QUOTA" -v m="$QUOTA_MIN" 'BEGIN { exit !(q + 0 >= m + 0) }'; then QUOTA_STATE="ok"; return 0; fi

  QUOTA_STATE="baja"
  spin "Buscando pedidos de aumento" quotas list-requested-service-quota-change-history-by-quota \
    --service-code sagemaker --quota-code "$QUOTA_CODE" \
    --query "RequestedQuotas[?Status=='PENDING' || Status=='CASE_OPENED'].[Status,DesiredValue]" \
    || { show_log; return 1; }
  QUOTA_REQUEST="$(awk '/^(PENDING|CASE_OPENED)/ {print $1; exit}' "$LOG")"
  if [ -n "$QUOTA_REQUEST" ]; then QUOTA_STATE="pedida"; fi
  return 0
}

print_quota() {
  case "$QUOTA_STATE" in
    ok)     ok   "Cuota de cómputo de SageMaker (ml.t3.xlarge, Processing jobs): ${QUOTA%.0} (mínimo $QUOTA_MIN)" ;;
    baja)   err  "Cuota de cómputo de SageMaker (ml.t3.xlarge, Processing jobs): ${QUOTA%.0} (mínimo $QUOTA_MIN)" ;;
    pedida) warn "Cuota de cómputo de SageMaker (ml.t3.xlarge, Processing jobs): ${QUOTA%.0}. El aumento ya está pedido ($QUOTA_REQUEST): AWS aún no responde" ;;
  esac
}

request_quota() {
  quotas request-service-quota-increase --service-code sagemaker --quota-code "$QUOTA_CODE" \
    --desired-value "$QUOTA_MIN" --query RequestedQuota.Status
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg do_env=0 do_quota=0 skipped=0

  for arg in "$@"; do
    case "$arg" in
      --repo=*)    REPO="${arg#*=}";    valid_repo "$REPO"       || die "--repo debe tener la forma usuario/repo: $REPO" ;;
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: tus sesiones de GitHub y AWS están en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  command -v gh  >/dev/null 2>&1 || die "Falta GitHub CLI: corre primero paso1.sh."
  command -v aws >/dev/null 2>&1 || die "Falta AWS CLI: corre primero paso1.sh."
  command -v git >/dev/null 2>&1 || die "Falta Git: corre primero paso1.sh."

  LOG="$(mktemp)" && BODY="$(mktemp)" || die "No se pudo crear un archivo temporal."
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  stage 1 "Revisar qué tienes"
  check_account
  check_repo
  read_environment || die "No se pudo leer el environment (ver el error arriba)."
  print_environment
  check_aws
  read_quota || die "No se pudo leer la cuota (ver el error arriba)."
  print_quota

  stage 2 "Confirmar los cambios"
  if [ "$ENV_STATE" = "ok" ] && [ "$QUOTA_STATE" != "baja" ]; then ok "No hay nada que cambiar"; fi
  if [ "$ENV_STATE" != "ok" ]; then
    if [ "$ENV_STATE" = "falta" ]; then
      echo "  - GitHub: crear el environment $ENVIRONMENT en $REPO, con $USER_LOGIN como aprobador"
    else
      echo "  - GitHub: corregir el environment $ENVIRONMENT de $REPO (lo demás se conserva):"
      if [ "$ENV_ME" != "true" ];    then echo "      agregar a $USER_LOGIN como aprobador"; fi
      if [ "$ENV_SELF" != "false" ]; then echo "      desmarcar Prevent self-review"; fi
    fi
    if confirm "¿Proceder?"; then do_env=1; else skipped=1; fi
  fi
  if [ "$QUOTA_STATE" = "baja" ]; then
    echo "  - AWS: pedir el aumento de la cuota de ml.t3.xlarge en Processing jobs a $QUOTA_MIN (AWS decide si lo aprueba y cuándo)"
    if confirm "¿Pedirlo?"; then do_quota=1; else skipped=1; fi
  fi

  stage 3 "Configurar"
  if [ "$((do_env + do_quota))" -eq 0 ]; then ok "Nada que hacer"; fi
  if [ "$do_env" -eq 1 ]; then
    if spin "Guardando el environment en GitHub" save_environment; then
      ok "Environment $ENVIRONMENT: guardado"
    else
      show_log
      if grep 'HTTP 422' "$LOG" >/dev/null; then info "En un repo privado, los aprobadores requieren un plan de pago de GitHub."; fi
      die "GitHub no aceptó el cambio (ver el error arriba). Vuelve a correr este script."
    fi
  fi
  if [ "$do_quota" -eq 1 ]; then
    if spin "Pidiendo el aumento a AWS" request_quota; then
      ok "Aumento pedido (estado: $(tail -n 1 "$LOG"))"
    else
      show_log
      die "AWS no aceptó el pedido (ver el error arriba). Vuelve a correr este script."
    fi
  fi

  stage 4 "Comprobar"
  read_environment || die "No se pudo leer el environment (ver el error arriba)."
  print_environment
  read_quota || die "No se pudo leer la cuota (ver el error arriba)."
  print_quota

  if [ "$ENV_STATE" = "ok" ] && [ "$QUOTA_STATE" = "ok" ]; then
    title "Todo listo. Puedes seguir con la infraestructura."
    exit 0
  fi
  echo
  if [ "$skipped" -eq 1 ]; then warn "Dejaste cambios sin aplicar. Cuando quieras, vuelve a correr este script."; fi
  if [ "$ENV_STATE" = "ok" ] && [ "$QUOTA_STATE" != "ok" ]; then
    warn "Puedes levantar la infraestructura, pero no entrenar hasta que la cuota sea $QUOTA_MIN o más. Vuelve a correr este script para revisarla."
  fi
  exit 1
}

main "$@"
