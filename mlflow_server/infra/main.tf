# MLflow tracking server desechable en AWS (ver ../docs/architecture.md).
#   S3 (estado + artefactos) ← EC2 (Docker: MLflow + Litestream) ← Elastic IP ← CloudFront (HTTPS) ← clientes
# Sin SSH: administración por SSM. La EC2 se puede destruir y recrear: restaura el estado desde S3.

data "aws_caller_identity" "current" {}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  bucket            = "${var.name}-${local.account_id}"
  artifacts_prefix  = "artifacts"
  registry_prefix   = "registry"
  password_param    = "/${var.name}/admin-password"
  image_uri         = "${aws_ecr_repository.mlflow.repository_url}:${var.image_tag}"
  ecr_registry_host = split("/", aws_ecr_repository.mlflow.repository_url)[0]
}

# ---------------------------------------------------------------------------
# S3: fuente de verdad (réplicas de las bases SQLite + artefactos). Sin versioning: Litestream ya guarda
# historial (retention) y el versioning acumularía sus segmentos viejos para siempre.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "mlflow" {
  bucket = local.bucket
  # Solo `make destroy-all CONFIRM=yes` lo alcanza; `make down` conserva el bucket (y con él el estado).
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "mlflow" {
  bucket                  = aws_s3_bucket.mlflow.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow" {
  bucket = aws_s3_bucket.mlflow.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mlflow" {
  bucket = aws_s3_bucket.mlflow.id
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# ECR: imagen del servidor (tags inmutables = commit de git)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "mlflow" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "mlflow" {
  repository = aws_ecr_repository.mlflow.name
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
# Contraseña del admin (SSM SecureString). Solo se usa la primera vez que arranca con la base de usuarios vacía.
# ---------------------------------------------------------------------------
resource "random_password" "admin" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "admin_password" {
  name  = local.password_param
  type  = "SecureString"
  value = random_password.admin.result
}

# ---------------------------------------------------------------------------
# IAM de la EC2: SSM (sin SSH), leer la imagen, leer la contraseña, leer/escribir su bucket
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

resource "aws_iam_role" "mlflow" {
  name               = "${var.name}-server"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.mlflow.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "mlflow" {
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "ECRPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.mlflow.arn]
  }
  statement {
    sid       = "AdminPassword"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.admin_password.arn]
  }
  statement {
    sid       = "Bucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.mlflow.arn]
  }
  statement {
    sid       = "Objects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.mlflow.arn}/*"]
  }
}

resource "aws_iam_role_policy" "mlflow" {
  name   = "server"
  role   = aws_iam_role.mlflow.id
  policy = data.aws_iam_policy_document.mlflow.json
}

resource "aws_iam_instance_profile" "mlflow" {
  name = "${var.name}-server"
  role = aws_iam_role.mlflow.name
}

# ---------------------------------------------------------------------------
# Red: VPC y subred por defecto. Al puerto 5000 solo llega CloudFront (prefix list administrada por AWS).
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

resource "aws_security_group" "mlflow" {
  name        = "${var.name}-server"
  description = "MLflow: solo CloudFront entra al 5000; sin SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MLflow desde CloudFront"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "Salida (ECR, S3, SSM, paquetes)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IP fija: el origen de CloudFront no cambia aunque la EC2 se apague o se reemplace.
resource "aws_eip" "mlflow" {
  domain = "vpc"
  tags   = { Name = "${var.name}-server" }
}

# ---------------------------------------------------------------------------
# EC2 desechable. Cambiar la imagen o la config la REEMPLAZA (user_data_replace_on_change) y la nueva
# restaura el estado desde S3.
# ---------------------------------------------------------------------------
resource "aws_instance" "mlflow" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.mlflow.id]
  iam_instance_profile   = aws_iam_instance_profile.mlflow.name

  metadata_options {
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 2          # los contenedores también usan el rol de la EC2
  }

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true # desechable: el estado está en S3
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region           = var.region
    compose_b64      = filebase64("${path.module}/../compose.yml")
    litestream_b64   = filebase64("${path.module}/../litestream.yml")
    compose_version  = var.compose_version
    compose_sha256   = var.compose_sha256
    ecr_registry     = local.ecr_registry_host
    image_uri        = local.image_uri
    bucket           = aws_s3_bucket.mlflow.bucket
    artifacts_prefix = local.artifacts_prefix
    registry_prefix  = local.registry_prefix
    password_param   = aws_ssm_parameter.admin_password.name
    allowed_host     = aws_eip.mlflow.public_dns
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.name}-server" }
}

resource "aws_eip_association" "mlflow" {
  allocation_id = aws_eip.mlflow.id
  instance_id   = aws_instance.mlflow.id
}

# ---------------------------------------------------------------------------
# CloudFront: HTTPS sin dominio propio (*.cloudfront.net). Sin caché.
# Authorization va en la cache policy (CloudFront solo lo reenvía así); TTL 0 = nada se cachea.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_cache_policy" "mlflow" {
  name        = "${var.name}-no-cache"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 1
  parameters_in_cache_key_and_forwarded_to_origin {
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Authorization"]
      }
    }
    cookies_config {
      cookie_behavior = "all"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "mlflow" {
  enabled         = true
  comment         = "${var.name} tracking server"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    origin_id   = "mlflow"
    domain_name = aws_eip.mlflow.public_dns
    custom_origin_config {
      http_port                = 5000
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id         = "mlflow"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.mlflow.id
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
