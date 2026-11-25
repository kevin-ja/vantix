# GitHub: sesión, repo, environment y variables. Se carga con `.`; compatible con bash 3.2.

ENVIRONMENT="production"     # fijo: lo exigen los workflows y los roles de AWS
REPO="$GITHUB_REPO"
USER_LOGIN=""; USER_ID=""

github() { gh api --hostname github.com "$@"; }

stop_if_offline() {
  if grep -iE 'error connecting|could not resolve|no such host|timeout|timed out|HTTP 5[0-9][0-9]|rate limit' "$LOG" >/dev/null; then
    show_log
    die "GitHub no respondió. Revisa tu conexión y vuelve a intentarlo."
  fi
}

check_account() {
  command -v gh >/dev/null 2>&1 || die "Falta GitHub CLI: corre primero make train-up."
  if ! spin "Comprobando tu sesión de GitHub" github user --jq '[.login, (.id | tostring)] | @tsv'; then
    stop_if_offline
    die "No hay sesión de GitHub: corre primero make train-up."
  fi
  USER_LOGIN="$(tail -n 1 "$LOG" | cut -f 1)"
  USER_ID="$(tail -n 1 "$LOG" | cut -f 2)"
  env_matches "$USER_ID" '^[0-9]+$' || die "GitHub respondió una cuenta inesperada."
  ok "Cuenta de GitHub: $USER_LOGIN"
}

check_repo() {
  local admin
  if ! spin "Buscando $REPO en GitHub" github "repos/$REPO" --jq '[.full_name, (.permissions.admin | tostring)] | @tsv'; then
    stop_if_offline
    die "$REPO no existe, o la cuenta $USER_LOGIN no puede verlo. Revisa GITHUB_REPO en .env."
  fi
  REPO="$(tail -n 1 "$LOG" | cut -f 1)"
  admin="$(tail -n 1 "$LOG" | cut -f 2)"
  [ "$admin" = "true" ] || die "La cuenta $USER_LOGIN no administra $REPO. Usa tu copia (GITHUB_REPO en .env) o cambia de cuenta con: gh auth login"
  ok "Repo: $REPO"
}

check_environment() {
  if ! spin "Buscando el environment $ENVIRONMENT" github "repos/$REPO/environments/$ENVIRONMENT" --jq .name; then
    stop_if_offline
    if grep 'HTTP 404' "$LOG" >/dev/null; then die "No existe el environment $ENVIRONMENT: corre primero make train-up."; fi
    show_log
    die "No se pudo leer el environment (ver el error arriba)."
  fi
  ok "Environment: $ENVIRONMENT"
}

# --- variables ------------------------------------------------------------------
# El paso define:
#   SPECS      "NOMBRE|módulo|output|patrón"  (ACCOUNT en el patrón = la cuenta)
#   SCOPE      "env" (environment production) o "repo"
#   SOURCE     comando que levanta esa infraestructura, para los mensajes
#   TRUST_ROLE variable con el rol que debe confiar en el repo
#   TRUST_SUB  "environment:production" o "ref:refs/heads/main"
SPECS=(); PENDING=(); SCOPE="env"; SOURCE=""; TRUST_ROLE=""; TRUST_SUB=""

lookup()   { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
value_of() { lookup "$WORK/values" "$1"; }
current()  { lookup "$WORK/current" "$1"; }

read_values() {
  local spec name module output pattern value
  : > "$WORK/values"
  for spec in "${SPECS[@]}"; do
    IFS='|' read -r name module output pattern <<SPEC
$spec
SPEC
    pattern="$(printf '%s' "$pattern" | sed "s/ACCOUNT/$ACCOUNT_ID/")"
    spin "Leyendo $output" tf "$module" output -raw "$output" \
      || { show_log; die "La infraestructura no está levantada o está incompleta (falta $output): corre primero $SOURCE."; }
    value="$(tail -n 1 "$LOG")"
    # Sin infraestructura, `output` puede devolver un aviso en vez del valor.
    printf '%s\n' "$value" | grep -E -- "$pattern" >/dev/null \
      || die "El valor de $output no es el esperado para la cuenta $ACCOUNT_ID: corre primero $SOURCE. No se cambió nada."
    printf '%s\t%s\n' "$name" "$value" >> "$WORK/values"
  done
  ok "Valores de la infraestructura: ${#SPECS[@]} leídos"
}

check_trust() {
  local prefix trusted role sub
  role="$(value_of "$TRUST_ROLE")"
  spin "Leyendo cómo se identifica el repo" github "repos/$REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix // "-"' \
    || { stop_if_offline; show_log; die "GitHub no dijo cómo se identifica el repo (ver el error arriba)."; }
  prefix="$(tail -n 1 "$LOG")"
  if [ "$prefix" = "-" ]; then prefix="repo:$REPO"; fi
  spin "Comprobando en quién confía AWS" aws iam get-role --role-name "${role##*/}" \
    --query 'Role.AssumeRolePolicyDocument' --output json \
    || { show_log; die "No se pudo leer el rol ${role##*/} (ver el error arriba): corre primero $SOURCE."; }
  sub="$(printf '%s' "$TRUST_SUB" | sed 's#/#\\/#g')"
  trusted="$(sed -nE 's/.*"(repo:[^"]*):'"$sub"'".*/\1/p' "$LOG" | head -n 1)"
  if [ "$trusted" != "$prefix" ]; then
    err "AWS confía en '${trusted:-nadie}' y tu repo se identifica como '$prefix'"
    die "Revisa GITHUB_REPO en .env y corre $SOURCE. No se cambió nada."
  fi
  ok "AWS confía en tu repo: ${prefix#repo:}"
}

read_current() {
  local where=()
  if [ "$SCOPE" = "env" ]; then where=(--env "$ENVIRONMENT"); fi
  if ! spin "Leyendo las variables de GitHub" gh variable list -R "github.com/$REPO" ${where[@]+"${where[@]}"} \
      --json name,value --jq '.[] | [.name, .value] | @tsv'; then
    stop_if_offline
    show_log
    die "No se pudieron leer las variables (ver el error arriba)."
  fi
  cp "$LOG" "$WORK/current"
}

# Deja en PENDING las variables que faltan o tienen otro valor.
compare() {
  local spec name
  PENDING=()
  for spec in "${SPECS[@]}"; do
    name="${spec%%|*}"
    if [ "$(current "$name")" = "$(value_of "$name")" ]; then
      ok "$name"
    elif [ -z "$(current "$name")" ]; then
      todo "$name: falta"
      PENDING+=("$name")
    else
      todo "$name: tiene otro valor"
      PENDING+=("$name")
    fi
  done
}

# Crea las que faltan sin preguntar. Cambiar el valor de una que ya existe pregunta, una sola vez para todas.
save_pending() {
  local name where=() changes=0
  if [ "$SCOPE" = "env" ]; then where=(--env "$ENVIRONMENT"); fi
  for name in ${PENDING[@]+"${PENDING[@]}"}; do
    if [ -z "$(current "$name")" ]; then continue; fi
    if [ "$changes" -eq 0 ]; then warn "Variables de $REPO que ya existen y cambiarán:"; fi
    changes=1
    echo "      $name"
    echo "        antes:   $(current "$name")"
    echo "        después: $(value_of "$name")"
  done
  if [ "$changes" -eq 1 ]; then confirm "¿Cambiarlas?" || die "No se cambió ninguna variable."; fi
  for name in ${PENDING[@]+"${PENDING[@]}"}; do
    task "Guardando $name" "$name: guardada" \
      gh variable set "$name" -R "github.com/$REPO" ${where[@]+"${where[@]}"} --body "$(value_of "$name")" \
      || die "GitHub no aceptó $name (ver el error arriba)."
  done
}
