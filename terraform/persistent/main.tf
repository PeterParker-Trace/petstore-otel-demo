# =============================================================================
# persistent/main.tf
#
# This stack creates resources that PERSIST across sessions:
#   - ECR repositories for our 5 service images
#   - AWS Secrets Manager entry for the Coralogix Send-Your-Data API key
#
# Apply this once. Don't destroy it between sessions.
# Cost: pennies/month for ECR storage + ~$0.40/month per secret in Secrets Manager.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
  # State lives locally for now. For team use, switch to an S3 backend later.
}

provider "aws" {
  region = var.aws_region

  # All resources created by this provider get these tags automatically.
  # Critical in shared sandbox accounts so YOUR resources are easy to find.
  default_tags {
    tags = {
      Project     = "petstore-otel-demo"
      ManagedBy   = "terraform"
      Environment = "sandbox"
      Owner       = var.owner
      Stack       = "persistent"
    }
  }
}

# =============================================================================
# ECR REPOSITORIES — one per service that has its own image
# =============================================================================
# We loop over a local list to avoid copy-pasting 5 nearly-identical resource blocks.
# This is idiomatic Terraform: prefer for_each over duplication.

locals {
  service_names = [
    "frontend",
    "api-gateway",
    "catalog-service",
    "orders-service",
    "payments-service",
  ]
}

resource "aws_ecr_repository" "service" {
  for_each = toset(local.service_names)

  name = "${var.project_prefix}/${each.key}"

  # Mutable: same tag (e.g. "latest") can be overwritten. Convenient for dev.
  # In production you'd use IMMUTABLE and version every push.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # free, basic vulnerability scan
  }

  # When we run `terraform destroy` someday, allow deletion even if images exist.
  force_delete = true
}

# Lifecycle policy — keep last 5 images per repo, expire older ones.
# Without this, you accumulate every old image you've ever pushed (storage cost grows linearly).
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 tagged images"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# =============================================================================
# SECRETS MANAGER — Coralogix Send-Your-Data API key
# =============================================================================
# We store the key here so ECS task definitions can pull it as a secret.
# This avoids ever putting the key in:
#   - Docker images
#   - Task definition JSON (which is logged/visible)
#   - Source control
#
# The secret VALUE is set out-of-band via AWS CLI (instructions in README).
# Terraform creates the secret resource but NOT its value — by design.

resource "aws_secretsmanager_secret" "coralogix_private_key" {
  name        = "${var.project_prefix}/coralogix_private_key"
  description = "Coralogix Send-Your-Data API key (cxtp_...) for OTEL Collector"

  # When destroying, delete immediately rather than the default 30-day grace period.
  # Safer in a sandbox where you're iterating frequently.
  recovery_window_in_days = 0
}
