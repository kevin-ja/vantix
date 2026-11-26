# Paso: Requisitos
#
# Solo lee. Comprueba lo que deja listo el entrenamiento, que haya un champion y datos, y lo que el monitoreo da por hecho
# en la cuenta: proveedor OIDC, VPC por defecto, subred y AMI.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

DIR="monitorization/infra"

# Valor por defecto de una variable de Terraform (zona y AMI están fijadas ahí).
tf_default() {
  awk -v key="$1" '$0 ~ "^variable \"" key "\"" { on = 1 } on && /default/ { split($0, part, "\""); print part[2]; exit }' "$ROOT/$DIR/variables.tf"
}

check_authorized() {
  local value
  value="$(tfvars_values "$ROOT/$DIR/terraform.tfvars" github_repo | head -n 1)"
  [ -n "$value" ] || die "Falta autorizar tu repo (github_repo en $DIR/terraform.tfvars): corre primero make train-up."
  ok "Repo autorizado: $value"
}

check_oidc() {
  spin "Buscando el proveedor OIDC de GitHub" aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" \
    || { show_log; die "No existe el proveedor OIDC de GitHub: corre primero make train-up."; }
  ok "Proveedor OIDC de GitHub: existe"
}

check_network() {
  local zone ami vpc subnet
  zone="$(tf_default availability_zone)"
  ami="$(tf_default ami_id)"
  spin "Buscando la VPC por defecto" aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text \
    || { show_log; die "No se pudieron leer las VPC."; }
  vpc="$(tail -n 1 "$LOG")"
  case "$vpc" in
    vpc-*) ok "VPC por defecto: $vpc" ;;
    *) die "La cuenta no tiene VPC por defecto en $REGION. Créala con: aws ec2 create-default-vpc --profile $PROFILE --region $REGION" ;;
  esac
  spin "Buscando la subred de $zone" aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=availability-zone,Values=$zone" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text \
    || { show_log; die "No se pudieron leer las subredes."; }
  subnet="$(tail -n 1 "$LOG")"
  case "$subnet" in
    subnet-*) ok "Subred por defecto en $zone: $subnet" ;;
    *) die "La VPC por defecto no tiene subred en $zone. Créala con: aws ec2 create-default-subnet --availability-zone $zone --profile $PROFILE --region $REGION" ;;
  esac
  if ! spin "Buscando la AMI" aws ec2 describe-images --region "$REGION" --image-ids "$ami" --query 'Images[0].State' --output text; then
    show_log
    die "La AMI fijada ($ami) no está disponible: hay que actualizar ami_id en $DIR/variables.tf."
  fi
  [ "$(tail -n 1 "$LOG")" = "available" ] || die "La AMI fijada ($ami) ya no está disponible: hay que actualizar ami_id en $DIR/variables.tf."
  ok "AMI: $ami disponible"
}

review() {
  check_account
  check_repo
  check_authorized
  check_aws
  check_state_bucket
  check_terraform
  check_oidc
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  check_champion
  read_lots
  check_network
}

run_step
