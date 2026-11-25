# Paso: Autorizar tu repo (OIDC)
#
# Inicia sesión en GitHub si hace falta, comprueba que administras GITHUB_REPO, pregunta a GitHub cómo se identifica el
# repo ante AWS y guarda ese valor (github_repo) en los terraform.tfvars. No cambia nada en AWS ni en GitHub.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

TFVARS=("infra/shared/terraform.tfvars" "monitorization/infra/terraform.tfvars")   # módulos con roles de GitHub
VALUE=""         # como se identifica ante AWS: owner@id/repo@id u owner/repo

# Deja en USER_LOGIN la cuenta activa. `gh auth status` no sirve: falla si otra cuenta guardada está vencida.
read_login() {
  USER_LOGIN=""
  if spin "Comprobando tu sesión de GitHub" github user --jq .login; then
    USER_LOGIN="$(tail -n 1 "$LOG")"
    return 0
  fi
  stop_if_offline
  return 1
}

# owner/repo del remoto "origin". Vacío si no hay o no es de github.com.
repo_from_origin() {
  git -C "$ROOT" remote get-url origin 2>/dev/null | sed -nE \
    -e 's#/+$##' -e 's#\.git$##' \
    -e 's#^(https?|ssh)://([^/@]+@)?github\.com(:[0-9]+)?/([^/]+/[^/]+)$#\4#p' \
    -e 's#^[^/@]+@github\.com:([^/]+/[^/]+)$#\1#p'
}

# Deja en VALUE cómo se presenta el repo en el token OIDC, sin el prefijo "repo:".
read_value() {
  local default immutable prefix
  if ! spin "Preguntando cómo se identifica ante AWS" github "repos/$REPO/actions/oidc/customization/sub" \
      --jq '[(.use_default | tostring), (.use_immutable_subject | tostring), (.sub_claim_prefix // "-")] | @tsv'; then
    stop_if_offline
    show_log
    die "GitHub no dijo cómo se identifica el repo (ver el error arriba)."
  fi
  default="$(tail -n 1 "$LOG" | cut -f 1)"
  immutable="$(tail -n 1 "$LOG" | cut -f 2)"
  prefix="$(tail -n 1 "$LOG" | cut -f 3)"

  if [ "$default" = "false" ]; then
    die "$REPO tiene un formato OIDC personalizado y los roles de Terraform esperan el normal. Restablécelo en GitHub."
  fi
  if [ "$prefix" != "-" ]; then
    VALUE="${prefix#repo:}"
  elif [ "$immutable" = "true" ]; then   # sin prefijo en la respuesta: se arma con los IDs
    spin "Leyendo los IDs del repo" github "repos/$REPO" --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"' \
      || { show_log; die "No se pudieron leer los IDs del repo."; }
    VALUE="$(tail -n 1 "$LOG")"
  else
    VALUE="$REPO"
  fi

  env_matches "$VALUE" '^[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$' \
    || die "GitHub respondió un identificador inesperado: $VALUE"
  # El identificador, sin los @ID, debe ser el mismo repo.
  if [ "$(printf '%s' "$VALUE" | sed -E 's/@[0-9]+//g' | tr '[:upper:]' '[:lower:]')" != \
       "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    die "El identificador ($VALUE) no corresponde a $REPO."
  fi
  ok "Identificador ante AWS: $VALUE"
}

check_identity() {
  local origin
  ok "Cuenta de GitHub: $USER_LOGIN"
  check_repo
  origin="$(repo_from_origin)"
  if [ -n "$origin" ] && [ "$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "GITHUB_REPO es $REPO, pero esta carpeta se clonó de $origin: los workflows correrán el código de $REPO."
  fi
  read_value
}

tfvars_ready() { [ "$(tfvars_values "$ROOT/$1" github_repo)" = "$VALUE" ]; }

NO_LOGIN=0
review() {
  local file
  NO_LOGIN=0
  have gh  || die "Falta GitHub CLI."
  have git || die "Falta Git."
  if ! read_login; then
    todo "Cuenta de GitHub: sin sesión, o con la sesión vencida"
    NO_LOGIN=1
    return 0
  fi
  check_identity
  for file in "${TFVARS[@]}"; do
    if tfvars_ready "$file"; then ok "$file: github_repo listo"; else todo "$file: falta github_repo o tiene otro valor"; fi
  done
}

apply() {
  local file before
  if [ "$NO_LOGIN" -eq 1 ]; then
    if [ -n "$GH_TOKEN$GITHUB_TOKEN" ]; then
      die "Tu terminal tiene GH_TOKEN o GITHUB_TOKEN, que mandan sobre el inicio de sesión. Quítalas: unset GH_TOKEN GITHUB_TOKEN"
    fi
    info "Copia el código que aparecerá, pulsa Enter y pégalo en el navegador para autorizar el acceso a GitHub."
    echo
    gh auth login --hostname github.com --git-protocol https --web || die "No se pudo iniciar sesión (ver el error arriba)."
    echo
    read_login || { show_log; die "GitHub no aceptó la sesión."; }
    check_identity
  fi
  for file in "${TFVARS[@]}"; do
    if tfvars_ready "$file"; then continue; fi
    before="$(tfvars_values "$ROOT/$file" github_repo | paste -s -d ' ' -)"
    tfvars_set "$ROOT/$file" github_repo "$VALUE" || die "No se pudo escribir $file."
    if [ -n "$before" ]; then info "$file: antes decía $before (se guardó una copia)"; fi
    ok "$file: github_repo = \"$VALUE\""
  done
}

run_step
