# =============================================================================
# ephemeral/task-definition-postgres.tf - Chunk B4
#
# Postgres runs as an ECS task. Simple: one container, no sidecar.
# Data is ephemeral (lost on task replacement) but the init.sql runs on first
# start to seed the schema.
#
# In production you'd use RDS. For our demo, this is fast and free.
# =============================================================================

# -----------------------------------------------------------------------------
# Container definition (JSON)
# -----------------------------------------------------------------------------
# ECS task definitions take container_definitions as a JSON string. We build
# it with jsonencode() so we can use Terraform references naturally.

locals {
  postgres_container = {
    name      = "postgres"
    image     = "${local.ecr_repository_urls["postgres"]}:latest"
    cpu       = 256
    memory    = 512
    essential = true

    environment = [
      { name = "POSTGRES_USER", value = "petstore" },
      { name = "POSTGRES_PASSWORD", value = "petstore" }, # OK for demo; in production use Secrets Manager
      { name = "POSTGRES_DB", value = "petstore" },
    ]

    portMappings = [
      {
        containerPort = 5432
        hostPort      = 5432
        protocol      = "tcp"
      }
    ]

    healthCheck = {
      command     = ["CMD-SHELL", "pg_isready -U petstore -d petstore || exit 1"]
      interval    = 10
      timeout     = 5
      retries     = 5
      startPeriod = 30
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "postgres"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Task Definition
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "postgres" {
  family                   = "${var.project_prefix}-postgres"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Runtime platform: explicitly target ARM64 (matches our Graviton instances)
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([local.postgres_container])
}

# -----------------------------------------------------------------------------
# ECS Service - keeps 1 Postgres task running
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "postgres" {
  name            = "postgres"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.postgres.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_tasks.id, aws_security_group.postgres.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service["postgres"].arn
  }

  # Note: not using a load balancer - postgres is internal-only via Cloud Map.

  # Give the task time to start before declaring it failed.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
}
