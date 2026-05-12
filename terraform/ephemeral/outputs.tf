# =============================================================================
# ephemeral/outputs.tf
# =============================================================================

# --- B1 Networking ---
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "ecs_tasks_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}

output "postgres_security_group_id" {
  value = aws_security_group.postgres.id
}

output "availability_zones" {
  value = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- B2 ECS Cluster + ASG ---
output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "asg_name" {
  value = aws_autoscaling_group.ecs_nodes.name
}

output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "cloudwatch_log_group_name" {
  value = aws_cloudwatch_log_group.ecs.name
}

# --- B3 ALB + Service Discovery ---
output "alb_dns_name" {
  description = "Public DNS name of the ALB - this is where you visit the app"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "frontend_target_group_arn" {
  description = "Target group ARN that the frontend ECS service registers with"
  value       = aws_lb_target_group.frontend.arn
}

output "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace ID"
  value       = aws_service_discovery_private_dns_namespace.main.id
}

output "service_discovery_service_arns" {
  description = "Map of service name to Cloud Map service ARN"
  value       = { for k, v in aws_service_discovery_service.service : k => v.arn }
}
