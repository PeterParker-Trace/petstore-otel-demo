# =============================================================================
# persistent/outputs.tf
#
# Outputs are values Terraform prints after `apply`, OR that other stacks read
# via `terraform_remote_state` data sources. The ephemeral stack will need
# these to know which ECR URLs to reference and which secret to mount.
# =============================================================================

output "ecr_repository_urls" {
  description = "Map of service name -> ECR repository URL (for docker push)"
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}

output "ecr_registry_url" {
  description = "ECR registry URL (host portion only) for `docker login`"
  value       = split("/", values(aws_ecr_repository.service)[0].repository_url)[0]
}

output "coralogix_secret_arn" {
  description = "ARN of the Coralogix Secrets Manager entry"
  value       = aws_secretsmanager_secret.coralogix_private_key.arn
}

output "coralogix_secret_name" {
  description = "Name of the Coralogix secret (use with `aws secretsmanager put-secret-value`)"
  value       = aws_secretsmanager_secret.coralogix_private_key.name
}
