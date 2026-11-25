# Terraform: versión, init, plan, apply y tfvars. Se carga con `.`; compatible con bash 3.2.

TERRAFORM_VERSION="1.15.8"   # exacta: la exige mlflow_server/infra/versions.tf

# Las mismas variables para todos los módulos que las usan.
export TF_VAR_aws_profile="$PROFILE" TF_VAR_region="$REGION" TF_VAR_state_bucket="$STATE_BUCKET"

check_terraform() {
  local version
  command -v terraform >/dev/null 2>&1 || die "Falta Terraform: corre primero make train-up."
  # Variables de la terminal que cambiarían lo que hace Terraform.
  unset TF_WORKSPACE TF_DATA_DIR TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_output
  export TF_IN_AUTOMATION=1
  version="$(terraform version | awk 'NR == 1 {sub(/^v/, "", $2); print $2}')"
  [ "$version" = "$TERRAFORM_VERSION" ] || die "Terraform es $version y se necesita $TERRAFORM_VERSION: corre primero make train-up."
  ok "Terraform: $version"
}

tf() { local dir="$1"; shift; terraform -chdir="$ROOT/$dir" "$@"; }

# tf_init <módulo> <clave del estado>
tf_init() {
  spin "Preparando Terraform en $1" tf "$1" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$2" -backend-config="region=$REGION" \
    -backend-config="profile=$PROFILE" -backend-config="use_lockfile=true" \
    || { show_log; die "No se pudo preparar Terraform en $1 (ver el error arriba)."; }
}

# tf_plan <módulo> [opciones] -> 0 sin cambios, 2 con cambios (quedan en $WORK/plan). Si falla, se detiene.
# Con `check` no bloquea el estado: solo lee.
tf_plan() {
  local dir="$1" rc lock="true"
  shift
  if [ "$SETUP_MODE" = "check" ]; then lock="false"; fi
  spin "Calculando los cambios de $dir" tf "$dir" plan -input=false -lock="$lock" -detailed-exitcode -out="$WORK/plan" "$@"
  rc=$?
  case "$rc" in
    0|2) return "$rc" ;;
    *) show_log; die "No se pudieron calcular los cambios de $dir (ver el error arriba)." ;;
  esac
}

# Muestra el plan: solo la lista si todo es nuevo, o completo si toca algo que ya existe. Queda en $WORK/plan.txt.
show_plan() {
  tf "$1" show -no-color "$WORK/plan" > "$WORK/plan.txt" || die "No se pudo leer el plan de $1."
  if [ -n "$SETUP_LOG" ]; then redact < "$WORK/plan.txt" | sed 's/^/    | /' >> "$SETUP_LOG"; fi
  if grep -E '^  # .* (will be updated|must be replaced|will be destroyed|is tainted)' "$WORK/plan.txt" >/dev/null; then
    cat "$WORK/plan.txt"
  else
    grep -E '^  # ' "$WORK/plan.txt"
    grep -E '^Plan:' "$WORK/plan.txt" | sed 's/^/  /'
  fi
}

# approve_plan <módulo>: crear o actualizar sigue (lo cubre la confirmación inicial); reemplazar o destruir pregunta;
# destruir datos se detiene. Usa el plan que mostró show_plan.
approve_plan() {
  local destroys='(must be replaced|will be destroyed|is tainted)'
  if grep -E "^  # (module\.[^ ]+\.)?aws_(s3_bucket|ebs_volume)\.[^ ]+ $destroys" "$WORK/plan.txt" >&2; then
    die "El plan de $1 borraría datos (arriba). No se aplicó nada: revisa el cambio antes de continuar."
  fi
  grep -E "^  # .* $destroys" "$WORK/plan.txt" >/dev/null || return 0
  echo
  warn "ATENCIÓN: el plan de $1 DESTRUYE o REEMPLAZA recursos que ya existen:"
  grep -E "^  # .* $destroys" "$WORK/plan.txt"
  echo
  confirm "¿Aplicarlo en la cuenta $ACCOUNT_ID?" || die "No se aplicó $1."
}

# Deja pasar solo qué recurso empieza y cuál termina.
tf_lines() {
  awk '
    /: (Creating|Modifying|Destroying)\.\.\./          { sub(/ \[id=.*/, ""); print "  → " $0; fflush(); next }
    / (complete after|completed after) /               { sub(/ \[id=.*/, ""); print "  ✔ " $0; fflush(); next }
    /^Apply complete!/                                 { print "  ✔ " $0; fflush() }'
}

# Aplica exactamente el plan mostrado.
tf_apply() {
  live tf_lines tf "$1" apply -input=false -no-color "$WORK/plan" \
    || { show_log; die "Terraform falló en $1 (ver el error arriba)."; }
}

# infra/shared lee el estado de MLflow: sin él, Terraform fallaría con un error difícil de entender.
check_mlflow_state() {
  spin "Buscando MLflow" aws s3api head-object --bucket "$STATE_BUCKET" --key mlflow-server/terraform.tfstate \
    || { show_log; die "MLflow no está levantado: corre primero make train-up."; }
  ok "MLflow: levantado"
}

check_github_repo() {
  local value
  value="$(tfvars_values "$ROOT/infra/shared/terraform.tfvars" github_repo)"
  [ -n "$value" ] || die "Falta autorizar tu repo (github_repo en infra/shared/terraform.tfvars): corre primero make train-up."
  ok "Repo autorizado: $value"
}

# AWS admite un solo proveedor OIDC de GitHub por cuenta. Si ya hay uno ajeno a este proyecto, Terraform fallaría a medias.
check_oidc_conflict() {
  local arn="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
  grep 'aws_iam_openid_connect_provider.github will be created' "$WORK/plan.txt" >/dev/null || return 0
  if spin "Buscando otro proveedor OIDC de GitHub" aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn"; then
    err "La cuenta ya tiene un proveedor OIDC de GitHub que no creó este proyecto: $arn"
    die "Usa una cuenta dedicada a Vantix. No se aplicó este módulo."
  fi
  grep 'NoSuchEntity' "$LOG" >/dev/null || { show_log; die "No se pudo comprobar el proveedor OIDC."; }
}

# tf_review <módulo> <clave del estado> [opciones] -> 0 al día, 1 hay cambios (los anota con todo)
tf_review() {
  local dir="$1" key="$2"
  shift 2
  tf_init "$dir" "$key"
  if tf_plan "$dir" "$@"; then ok "$dir: al día"; return 0; fi
  todo "$dir: hay cambios por aplicar"
  return 1
}

# tf_up <módulo> <clave del estado> [opciones]: muestra los cambios y los aplica (ver approve_plan)
tf_up() {
  local dir="$1" key="$2"
  shift 2
  tf_init "$dir" "$key"
  if tf_plan "$dir" "$@"; then return 0; fi
  info "Cambios en $dir:"
  show_plan "$dir"
  check_oidc_conflict
  approve_plan "$dir"
  tf_apply "$dir"
}

# tfvars_set <archivo> <variable> <valor>: deja una sola línea con ese valor y conserva el resto. Guarda copia.
tfvars_set() {
  local file="$1" key="$2" value="$3" dir part
  dir="$(dirname "$file")"
  # Los nombres terminan en .tfvars para que .gitignore los excluya; Terraform solo carga terraform.tfvars.
  part="$dir/nuevo.$$.tfvars"
  if [ -f "$file" ]; then
    cp -p "$file" "$dir/anterior.$(date +%Y%m%d%H%M%S).tfvars" && cp -p "$file" "$part" || return 1
  else
    ( umask 077 && : > "$part" ) || return 1
  fi
  awk -v key="$key" -v line="$key = \"$value\"" '
    { text = $0; sub(/^[ \t]+/, "", text) }
    index(text, key) == 1 && substr(text, length(key) + 1) ~ /^[ \t]*=/ { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }' "$([ -f "$file" ] && printf '%s' "$file" || printf /dev/null)" > "$part" \
    || { rm -f "$part"; return 1; }
  mv "$part" "$file"
}

# tfvars_values <archivo> <variable> -> sus valores, uno por línea
tfvars_values() {
  [ -f "$1" ] || return 0
  awk -v key="$2" '{ line = $0; sub(/^[ \t]+/, "", line) }
    index(line, key) == 1 && substr(line, length(key) + 1) ~ /^[ \t]*=/ { split(line, part, "\""); print part[2] }' "$1"
}
