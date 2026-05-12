# =============================================================================
# ephemeral/main.tf
#
# This stack creates resources that are CREATED AND DESTROYED per session:
#   - VPC + networking (Chunk B1)
#   - ECS cluster + EC2 ASG (Chunk B2)
#   - Service discovery + ALB (Chunk B3)
#   - Task definitions + ECS services (Chunk B4)
#
# We split into B1-B4 chunks so each can be applied and verified independently.
# All chunks share state. After all chunks are done, `terraform apply` here
# provisions the whole thing; `terraform destroy` tears it all down.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Tag everything so we can identify our resources in the shared sandbox.
  default_tags {
    tags = {
      Project     = "petstore-otel-demo"
      ManagedBy   = "terraform"
      Environment = "sandbox"
      Owner       = var.owner
      Stack       = "ephemeral"
    }
  }
}

# =============================================================================
# Read outputs from the persistent stack
# =============================================================================
# `terraform_remote_state` lets one stack read another's outputs. This is how
# we get ECR URLs and the Coralogix secret ARN without hardcoding them here.
# The persistent stack must have been applied first.
data "terraform_remote_state" "persistent" {
  backend = "local"
  config = {
    path = "../persistent/terraform.tfstate"
  }
}

# Locals derived from persistent state outputs. Used throughout this stack.
locals {
  ecr_registry_url     = data.terraform_remote_state.persistent.outputs.ecr_registry_url
  ecr_repository_urls  = data.terraform_remote_state.persistent.outputs.ecr_repository_urls
  coralogix_secret_arn = data.terraform_remote_state.persistent.outputs.coralogix_secret_arn
}

# =============================================================================
# Look up available AZs in our region
# =============================================================================
# Rather than hardcoding "eu-north-1a", "eu-north-1b", etc., we ask AWS what's
# available. Makes the code portable to other regions.
data "aws_availability_zones" "available" {
  state = "available"
}
