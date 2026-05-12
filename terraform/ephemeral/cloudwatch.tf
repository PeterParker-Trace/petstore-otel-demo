# =============================================================================
# ephemeral/cloudwatch.tf - Chunk B2
#
# ECS task containers write their stdout/stderr to CloudWatch Logs. This is
# in addition to whatever they send via OTEL to Coralogix - useful as a
# diagnostic fallback if OTEL is misconfigured.
# =============================================================================

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_prefix}"
  retention_in_days = 7 # Keep logs for 7 days then auto-delete

  # Without this, log group retention is forever and costs accumulate.
}
