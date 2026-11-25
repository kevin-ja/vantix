# Paso: Environment production y cuota de SageMaker
#
# GitHub: crea el environment con tu cuenta como aprobador; si ya existe, corrige solo lo que falte, y antes pregunta.
# AWS:    comprueba la cuota de ml.t3.xlarge en Processing jobs y, si es menor que 1, ofrece pedir el aumento. Una cuota
#         baja no impide levantar la infraestructura, pero sí entrenar.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

QUOTA_NAME="ml.t3.xlarge for processing job usage"
QUOTA_MIN=1                  # Prepare y Train corren uno después del otro, cada uno en una máquina

# Lee el environment. Deja en ENV_STATE: falta | corregir | ok.
ENV_STATE=""; ENV_REVIEWERS=""; ENV_ME=""; ENV_SELF=""; ENV_WAIT=""; ENV_BRANCHES=""
read_environment() {
  local jq name
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
    die "No se pudo leer el environment (ver el error arriba)."
  fi
  name="$(tail -n 1 "$LOG" | cut -f 1)"
  ENV_REVIEWERS="$(tail -n 1 "$LOG" | cut -f 2)"
  ENV_ME="$(tail -n 1 "$LOG" | cut -f 3)"
  ENV_SELF="$(tail -n 1 "$LOG" | cut -f 4)"
  ENV_WAIT="$(tail -n 1 "$LOG" | cut -f 5)"
  ENV_BRANCHES="$(tail -n 1 "$LOG" | cut -f 6)"
  [ "$name" = "$ENVIRONMENT" ] \
    || die "El environment se llama '$name' y debe llamarse '$ENVIRONMENT' (minúsculas): bórralo en GitHub."
  if [ "$ENV_ME" = "true" ] && [ "$ENV_SELF" = "false" ]; then ENV_STATE="ok"; else ENV_STATE="corregir"; fi
}

review_environment() {
  read_environment
  case "$ENV_STATE" in
    falta)    todo "Environment $ENVIRONMENT: no existe"; return 0 ;;
    ok)       ok "Environment $ENVIRONMENT: existe (aprobadores: $ENV_REVIEWERS)" ;;
    corregir) todo "Environment $ENVIRONMENT: existe, pero hay que corregirlo" ;;
  esac
  if [ "$ENV_WAIT" != "0" ];       then warn "Cada corrida espera además $ENV_WAIT min (wait timer)"; fi
  if [ "$ENV_BRANCHES" = "true" ]; then warn "Solo acepta ciertas ramas: comprueba en GitHub que main esté permitida"; fi
}

# La API reemplaza toda la configuración: si el environment existe, se parte de la actual para no perder nada.
save_environment() {
  local jq body="$WORK/environment.json"
  if [ "$ENV_STATE" = "falta" ]; then
    printf '{"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}]}\n' "$USER_ID" > "$body" || return 1
  else
    jq='{wait_timer: ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer] | add // 0),
         prevent_self_review: false,
         reviewers: ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | {type, id: .reviewer.id}]
                     + [{type: "User", id: '"$USER_ID"'}] | unique),
         deployment_branch_policy: (.deployment_branch_policy
           | if . == null then null else {protected_branches, custom_branch_policies} end)}'
    github "repos/$REPO/environments/$ENVIRONMENT" --jq "$jq" > "$body" || return 1
  fi
  github --method PUT "repos/$REPO/environments/$ENVIRONMENT" --input "$body" --silent
}

# --- cuota --------------------------------------------------------------------
quotas() { aws service-quotas "$@" --profile "$PROFILE" --region "$REGION" --output text; }

QUOTA_CODE=""; QUOTA=""; QUOTA_STATE=""; QUOTA_REQUEST=""
# Deja en QUOTA_STATE: ok | baja | pedida.
read_quota() {
  local query="Quotas[?QuotaName=='$QUOTA_NAME'].[QuotaCode,Value]"
  spin "Leyendo la cuota de cómputo de SageMaker" quotas list-service-quotas --service-code sagemaker --query "$query" \
    || { show_log; die "No se pudo leer la cuota (ver el error arriba)."; }
  QUOTA_CODE="$(awk '/^L-/ {print $1; exit}' "$LOG")"
  if [ -z "$QUOTA_CODE" ]; then   # sin valor propio en la cuenta: rige el que AWS da por defecto
    spin "Leyendo la cuota por defecto" quotas list-aws-default-service-quotas --service-code sagemaker --query "$query" \
      || { show_log; die "No se pudo leer la cuota (ver el error arriba)."; }
    QUOTA_CODE="$(awk '/^L-/ {print $1; exit}' "$LOG")"
  fi
  QUOTA="$(awk '/^L-/ {print $2; exit}' "$LOG")"
  if [ -z "$QUOTA_CODE" ] || ! env_matches "$QUOTA" '^[0-9]+(\.[0-9]+)?$'; then
    die "AWS no devolvió la cuota '$QUOTA_NAME'."
  fi
  if awk -v q="$QUOTA" -v m="$QUOTA_MIN" 'BEGIN { exit !(q + 0 >= m + 0) }'; then QUOTA_STATE="ok"; return 0; fi

  QUOTA_STATE="baja"
  spin "Buscando pedidos de aumento" quotas list-requested-service-quota-change-history-by-quota \
    --service-code sagemaker --quota-code "$QUOTA_CODE" \
    --query "RequestedQuotas[?Status=='PENDING' || Status=='CASE_OPENED'].[Status,DesiredValue]" \
    || { show_log; die "No se pudieron leer los pedidos de cuota (ver el error arriba)."; }
  QUOTA_REQUEST="$(awk '/^(PENDING|CASE_OPENED)/ {print $1; exit}' "$LOG")"
  if [ -n "$QUOTA_REQUEST" ]; then QUOTA_STATE="pedida"; fi
}

QUOTA_LABEL="Cuota de SageMaker (ml.t3.xlarge, Processing jobs)"
review_quota() {
  read_quota
  case "$QUOTA_STATE" in
    ok)     ok   "$QUOTA_LABEL: ${QUOTA%.0} (mínimo $QUOTA_MIN)" ;;
    baja)   todo "$QUOTA_LABEL: ${QUOTA%.0} (mínimo $QUOTA_MIN)" ;;
    pedida) warn "$QUOTA_LABEL: ${QUOTA%.0}. El aumento ya está pedido ($QUOTA_REQUEST): AWS aún no responde" ;;
  esac
}

request_quota() {
  quotas request-service-quota-increase --service-code sagemaker --quota-code "$QUOTA_CODE" \
    --desired-value "$QUOTA_MIN" --query RequestedQuota.Status
}

# --- flujo --------------------------------------------------------------------
review() {
  check_account
  check_repo
  review_environment
  check_aws
  review_quota
}

apply() {
  if [ "$ENV_STATE" = "corregir" ]; then
    echo "  El environment $ENVIRONMENT de $REPO cambiará (lo demás se conserva):"
    if [ "$ENV_ME" != "true" ];    then echo "    - aprobadores, hoy: $ENV_REVIEWERS → se agrega $USER_LOGIN"; fi
    if [ "$ENV_SELF" != "false" ]; then echo "    - Prevent self-review: marcado → desmarcado (no podrías aprobar tus corridas)"; fi
    confirm "¿Cambiarlo?" || die "No se cambió el environment."
  fi
  if [ "$ENV_STATE" != "ok" ]; then
    if spin "Guardando el environment en GitHub" save_environment; then
      ok "Environment $ENVIRONMENT: guardado, con $USER_LOGIN como aprobador"
    else
      show_log
      if grep 'HTTP 422' "$LOG" >/dev/null; then info "En un repo privado, los aprobadores requieren un plan de pago de GitHub."; fi
      die "GitHub no aceptó el cambio (ver el error arriba)."
    fi
  fi
  if [ "$QUOTA_STATE" = "baja" ]; then
    info "Se puede pedir a AWS el aumento a $QUOTA_MIN. AWS decide si lo aprueba y cuándo."
    if confirm "¿Pedirlo?"; then
      spin "Pidiendo el aumento a AWS" request_quota || { show_log; die "AWS no aceptó el pedido (ver el error arriba)."; }
      ok "Aumento pedido (estado: $(tail -n 1 "$LOG"))"
    fi
  fi
}

verify() {
  review_environment
  if [ "$QUOTA_STATE" != "ok" ]; then
    warn "Se puede levantar la infraestructura, pero no entrenar hasta que la cuota sea $QUOTA_MIN o más."
  fi
}

run_step
