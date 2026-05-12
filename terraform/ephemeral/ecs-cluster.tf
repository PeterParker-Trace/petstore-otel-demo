# =============================================================================
# ephemeral/ecs-cluster.tf - Chunk B2
#
# ECS Cluster (logical grouping) + Capacity Provider (bridge to the ASG).
#
# Order of creation (Terraform figures this out):
#   1. ECS Cluster
#   2. EC2 ASG (separately, in ec2-asg.tf)
#   3. Capacity Provider that references the ASG
#   4. Cluster Capacity Provider association
# =============================================================================

# -----------------------------------------------------------------------------
# ECS Cluster - logical grouping for tasks and services
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${var.project_prefix}-cluster"

  # Container Insights = optional CloudWatch metrics about cluster/task health.
  # Costs a little but useful for diagnostics. We keep it enabled.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# -----------------------------------------------------------------------------
# Capacity Provider - the bridge between the cluster and the EC2 ASG
# -----------------------------------------------------------------------------
# Without this, ECS doesn't know our ASG exists. The capacity provider says:
# "this ASG provides compute capacity to this cluster."
resource "aws_ecs_capacity_provider" "ec2_spot" {
  name = "${var.project_prefix}-ec2-spot"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs_nodes.arn

    # Managed scaling: ECS auto-scales the ASG based on task placement needs.
    # Without this, you'd have to manually scale the ASG when adding tasks.
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100 # try to use 100% of ASG capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }

    # Termination protection: ECS prevents the ASG from terminating an instance
    # that's still running tasks (until those tasks are drained gracefully).
    # Important - without this, Spot interruptions could yank instances mid-task.
    managed_termination_protection = "DISABLED"
    # Note: We set DISABLED because Spot instances cannot be protected from
    # scale-in (Spot termination is forced anyway). For On-Demand or Mixed,
    # you'd set this to ENABLED.
  }
}

# -----------------------------------------------------------------------------
# Cluster-CapacityProvider Association
# -----------------------------------------------------------------------------
# Tells the cluster which capacity providers it can use AND sets the default
# strategy for tasks that don't explicitly choose one.
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.ec2_spot.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_spot.name
    base              = 1
    weight            = 100
  }
}
