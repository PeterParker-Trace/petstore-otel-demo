# =============================================================================
# ephemeral/ecs-services.tf - Chunk B4
#
# ECS Services for the 5 app task definitions.
# Each service:
#   - Keeps 1 task running
#   - Registers with its Cloud Map service entry
#   - frontend ALSO registers with the ALB target group
#
# Dependency ordering (Terraform figures this out from resource references):
#   1. postgres service starts first
#   2. catalog-service, payments-service start (they only need DB or nothing)
#   3. orders-service starts (needs catalog + payments)
#   4. api-gateway starts (needs catalog + orders)
#   5. frontend starts (needs api-gateway)
#
# In practice, ECS launches them in parallel and they retry until DNS resolves.
# Most resolve within 30-60 seconds of cluster having capacity.
# =============================================================================

# -----------------------------------------------------------------------------
# Catalog Service
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "catalog_service" {
  name            = "catalog-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.catalog_service.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service["catalog-service"].arn
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [aws_ecs_service.postgres]
}

# -----------------------------------------------------------------------------
# Payments Service
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "payments_service" {
  name            = "payments-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.payments_service.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service["payments-service"].arn
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
}

# -----------------------------------------------------------------------------
# Orders Service
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "orders_service" {
  name            = "orders-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.orders_service.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service["orders-service"].arn
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_service.catalog_service,
    aws_ecs_service.payments_service,
  ]
}

# -----------------------------------------------------------------------------
# API Gateway
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "api_gateway" {
  name            = "api-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_gateway.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service["api-gateway"].arn
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_service.catalog_service,
    aws_ecs_service.orders_service,
  ]
}

# -----------------------------------------------------------------------------
# Frontend - also tied to the ALB target group
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "frontend" {
  name            = "frontend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service["frontend"].arn
  }

  # THIS is what wires the frontend tasks into the ALB. Task IPs get registered
  # in the target group automatically; ALB sends them traffic.
  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Wait for the ALB listener to exist before creating this service.
  depends_on = [
    aws_lb_listener.http,
    aws_ecs_service.api_gateway,
  ]

  # When ALB target group binds, ECS sometimes needs longer for the first task
  # to be reported healthy. Default 60s grace period is fine.
  health_check_grace_period_seconds = 60
}
