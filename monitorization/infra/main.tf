# Sistema de monitorización de Vantix (ver ../doc/monitorization_arch.md §8).
#   EC2 (Docker Compose: backend job + PostgreSQL + Grafana) ← Elastic IP ← CloudFront (HTTPS) ← ML engineer
#   backend lee el bucket de datos (raw/, models/champion/) y escribe en el bucket del monitoreo (benchmark/, backups/)
#   Grafana envía alertas por SES (SMTP). Sin SSH: administración por SSM.
# La EC2 es reemplazable: los datos de Postgres y Grafana viven en un volumen EBS aparte.

data "aws_caller_identity" "current" {}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  bucket            = "${var.name}-${local.account_id}"
  image_uri         = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
  ecr_registry_host = split("/", aws_ecr_repository.backend.repository_url)[0]
  smtp_host         = "email-smtp.${var.region}.amazonaws.com:587"
  # Provisioning de Grafana (datasource, dashboard, alertas): se publica en S3 y la EC2 lo sincroniza al arrancar.
  grafana_dir   = "${path.module}/../grafana"
  grafana_files = fileset(local.grafana_dir, "**")
  grafana_hash  = sha1(join("", [for f in sort(tolist(local.grafana_files)) : "${f}:${filesha1("${local.grafana_dir}/${f}")}"]))
  # Esquema de Postgres: el mismo archivo que usa el backend; Postgres lo ejecuta al inicializar un volumen vacío.
  schema_file = "${path.module}/../src/monitoring/schema.sql"
  params = {
    postgres_password = "/${var.name}/postgres-password"
    grafana_password  = "/${var.name}/grafana-admin-password"
    smtp_user         = "/${var.name}/smtp-user"
    smtp_password     = "/${var.name}/smtp-password"
  }
}

data "aws_s3_bucket" "data" {
  bucket = var.data_bucket
}

# ---------------------------------------------------------------------------
# S3 del monitoreo: benchmark/ (métricas + psi_bins.json) y backups/ (pg_dump). Con versionado.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "monitoring" {
  bucket = local.bucket
}

resource "aws_s3_bucket_versioning" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "monitoring" {
  bucket                  = aws_s3_bucket.monitoring.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Cada corrida sube un backup nuevo; las versiones reemplazadas no se acumulan para siempre.
  rule {
    id     = "expire-old-backup-versions"
    status = "Enabled"
    filter {
      prefix = "backups/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_object" "grafana" {
  for_each = local.grafana_files
  bucket   = aws_s3_bucket.monitoring.id
  key      = "grafana/${each.value}"
  source   = "${local.grafana_dir}/${each.value}"
  etag     = filemd5("${local.grafana_dir}/${each.value}")
}

resource "aws_s3_object" "schema" {
  bucket = aws_s3_bucket.monitoring.id
  key    = "db/schema.sql"
  source = local.schema_file
  etag   = filemd5(local.schema_file)
}

# ---------------------------------------------------------------------------
# ECR: imagen del backend (tags inmutables = commit de git)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "backend" {
  name                 = "${var.name}-backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar las 10 imágenes más recientes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# SES: verifica el correo de alertas (AWS envía un correo de confirmación). En sandbox SES solo envía a
# direcciones verificadas: remitente y destino son el mismo correo.
# Grafana usa SMTP, que exige credenciales de un usuario IAM (solo puede enviar correo).
# ---------------------------------------------------------------------------
resource "aws_ses_email_identity" "alerts" {
  email = var.alert_email
}

resource "aws_iam_user" "smtp" {
  name = "${var.name}-smtp"
}

data "aws_iam_policy_document" "smtp" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = [aws_ses_email_identity.alerts.arn]
  }
}

resource "aws_iam_user_policy" "smtp" {
  name   = "send-alerts"
  user   = aws_iam_user.smtp.name
  policy = data.aws_iam_policy_document.smtp.json
}

resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name
}

# ---------------------------------------------------------------------------
# Secretos (SSM SecureString). La EC2 los lee al arrancar; no van en user_data.
# ---------------------------------------------------------------------------
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "grafana" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "postgres_password" {
  name  = local.params.postgres_password
  type  = "SecureString"
  value = random_password.postgres.result
}

resource "aws_ssm_parameter" "grafana_password" {
  name  = local.params.grafana_password
  type  = "SecureString"
  value = random_password.grafana.result
}

resource "aws_ssm_parameter" "smtp_user" {
  name  = local.params.smtp_user
  type  = "SecureString"
  value = aws_iam_access_key.smtp.id
}

resource "aws_ssm_parameter" "smtp_password" {
  name  = local.params.smtp_password
  type  = "SecureString"
  value = aws_iam_access_key.smtp.ses_smtp_password_v4
}

# ---------------------------------------------------------------------------
# IAM de la EC2: SSM (sin SSH), imagen, secretos, lectura del bucket de datos, lectura/escritura del suyo
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name               = "${var.name}-server"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "server" {
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "ECRPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.backend.arn]
  }
  statement {
    sid       = "Secrets"
    actions   = ["ssm:GetParameter"]
    resources = [for p in [aws_ssm_parameter.postgres_password, aws_ssm_parameter.grafana_password, aws_ssm_parameter.smtp_user, aws_ssm_parameter.smtp_password] : p.arn]
  }
  statement {
    sid       = "DataBucketList"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.data.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/*", "models/champion/*"]
    }
  }
  statement {
    sid       = "DataBucketRead"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.data.arn}/raw/*", "${data.aws_s3_bucket.data.arn}/models/champion/*"]
  }
  statement {
    sid       = "MonitoringBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.monitoring.arn]
  }
  statement {
    sid       = "MonitoringObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.monitoring.arn}/*"]
  }
}

resource "aws_iam_role_policy" "server" {
  name   = "server"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

resource "aws_iam_instance_profile" "server" {
  name = "${var.name}-server"
  role = aws_iam_role.server.name
}

# ---------------------------------------------------------------------------
# Red: VPC y subred por defecto. Al puerto de Grafana (3000) solo llega CloudFront. Postgres no se expone.
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "server" {
  name        = "${var.name}-server"
  description = "Monitoreo: solo CloudFront entra a Grafana (3000); sin SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Grafana desde CloudFront"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "Salida (ECR, S3, SSM, SES, paquetes)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IP fija: el origen de CloudFront no cambia aunque la EC2 se apague o se reemplace.
resource "aws_eip" "server" {
  domain = "vpc"
  tags   = { Name = "${var.name}-server" }
}

# ---------------------------------------------------------------------------
# Volumen EBS persistente: datos de Postgres y Grafana. Sobrevive al reemplazo de la EC2.
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.name}-data" }
}

# ---------------------------------------------------------------------------
# EC2 reemplazable. Cambiar la imagen o la config la REEMPLAZA (user_data_replace_on_change); el volumen
# de datos se vuelve a montar en la nueva.
# ---------------------------------------------------------------------------
resource "aws_instance" "server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.server.id]
  iam_instance_profile   = aws_iam_instance_profile.server.name

  metadata_options {
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 2          # los contenedores también usan el rol de la EC2
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true # el sistema; los datos están en aws_ebs_volume.data
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region              = var.region
    compose_b64         = filebase64("${path.module}/../compose.yml")
    compose_version     = var.compose_version
    compose_sha256      = var.compose_sha256
    ecr_registry        = local.ecr_registry_host
    image_uri           = local.image_uri
    data_volume_id      = replace(aws_ebs_volume.data.id, "-", "")
    data_bucket         = var.data_bucket
    monitoring_bucket   = aws_s3_bucket.monitoring.bucket
    grafana_domain      = aws_cloudfront_distribution.grafana.domain_name
    smtp_host           = local.smtp_host
    alert_email         = var.alert_email
    postgres_pwd_param  = aws_ssm_parameter.postgres_password.name
    grafana_pwd_param   = aws_ssm_parameter.grafana_password.name
    smtp_user_param     = aws_ssm_parameter.smtp_user.name
    smtp_password_param = aws_ssm_parameter.smtp_password.name
    config_hash         = sha1("${local.grafana_hash}${filesha1(local.schema_file)}") # cambia → se reemplaza la EC2
  })
  user_data_replace_on_change = true

  tags       = { Name = "${var.name}-server" }
  depends_on = [aws_s3_object.grafana, aws_s3_object.schema]
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.server.id
  stop_instance_before_detaching = true # desmontaje limpio de Postgres al reemplazar la EC2
}

resource "aws_eip_association" "server" {
  allocation_id = aws_eip.server.id
  instance_id   = aws_instance.server.id
}

# ---------------------------------------------------------------------------
# CloudFront: HTTPS sin dominio propio (*.cloudfront.net) delante de Grafana. Sin caché.
# ---------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "grafana" {
  enabled         = true
  comment         = "${var.name} Grafana"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    origin_id   = "grafana"
    domain_name = aws_eip.server.public_dns
    custom_origin_config {
      http_port                = 3000
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id         = "grafana"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
