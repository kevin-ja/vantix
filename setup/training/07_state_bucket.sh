# Paso: Bucket del estado de Terraform
#
# Crea vantix-<cuenta>-tfstate (versionado y sin acceso público). Si ya existe, solo corrige lo que falte; nunca borra.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

s3() { aws s3api "$@" --bucket "$STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID"; }

EXISTS=""; VERSIONING=""; PRIVATE=""
read_state_bucket() {
  EXISTS="falta"; VERSIONING="falta"; PRIVATE="falta"
  if ! spin "Buscando el bucket $STATE_BUCKET" s3 head-bucket; then
    if grep -E '\(404\)|Not Found' "$LOG" >/dev/null; then return 0; fi
    show_log
    die "No se puede usar el bucket $STATE_BUCKET: existe en otra cuenta, o AWS no respondió."
  fi
  EXISTS="ok"
  spin "Comprobando el versionado" s3 get-bucket-versioning --query Status --output text || { show_log; die "No se pudo leer el versionado."; }
  if [ "$(tail -n 1 "$LOG")" = "Enabled" ]; then VERSIONING="ok"; fi
  if spin "Comprobando el acceso público" s3 get-public-access-block --output text \
      --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]'; then
    if [ "$(tail -n 1 "$LOG" | tr '\t' ' ')" = "True True True True" ]; then PRIVATE="ok"; fi
  elif ! grep 'NoSuchPublicAccessBlockConfiguration' "$LOG" >/dev/null; then
    show_log
    die "No se pudo leer el acceso público."
  fi
}

review() {
  check_aws
  read_state_bucket
  if [ "$EXISTS" != "ok" ]; then todo "Bucket $STATE_BUCKET: no existe"; return 0; fi
  ok "Bucket $STATE_BUCKET: existe"
  if [ "$VERSIONING" = "ok" ]; then ok "Versionado: activado"; else todo "Versionado: desactivado"; fi
  if [ "$PRIVATE" = "ok" ]; then ok "Acceso público: bloqueado"; else todo "Acceso público: sin bloquear"; fi
}

apply() {
  if [ "$EXISTS" != "ok" ]; then
    task "Creando el bucket" "Bucket creado" aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
      || die "No se pudo crear el bucket (ver el error arriba)."
  fi
  if [ "$VERSIONING" != "ok" ]; then
    task "Activando el versionado" "Versionado activado" s3 put-bucket-versioning --versioning-configuration Status=Enabled \
      || die "No se pudo activar el versionado."
  fi
  if [ "$PRIVATE" != "ok" ]; then
    task "Bloqueando el acceso público" "Acceso público bloqueado" s3 put-public-access-block --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      || die "No se pudo bloquear el acceso público."
  fi
}

run_step
