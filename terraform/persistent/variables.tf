# =============================================================================
# persistent/variables.tf
# =============================================================================

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-north-1"
}

variable "project_prefix" {
  description = "Prefix used for all resource names (ECR repos, secrets, etc.)"
  type        = string
  default     = "petstore-otel-demo"
}

variable "owner" {
  description = "Tag value for the Owner tag (typically your username or email)"
  type        = string
  # No default — every apply must specify this. Forces accountability in shared accounts.
}
