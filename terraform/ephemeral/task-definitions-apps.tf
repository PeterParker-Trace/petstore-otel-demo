# =============================================================================
# ephemeral/task-definitions-apps.tf - Chunk B4
#
# 5 ECS task definitions, one per app service. Each task contains:
#   1. The application container (pulled from ECR)
#   2. The OTEL Collector sidecar container (otel/opentelemetry-collector-contrib)
#
# Both containers share localhost (same task = same network namespace).
# App sends OTLP to localhost:4318 -> Collector forwards to Coralogix.
#
# To keep the file readable we build container definitions via locals and
# inject service-specific values where needed.
# =============================================================================


# -----------------------------------------------------------------------------
# Shared environment variables for all app containers
# -----------------------------------------------------------------------------
# OTEL env vars common to every app. Service-specific values get appended.
#
# TODO: OTEL_EXPORTER_OTLP_ENDPOINT below assumes a sidecar collector on
# localhost. We removed the sidecar - you'll re-enable telemetry by deploying
# the Coralogix collector per their AWS ECS-EC2 docs:
#   https://coralogix.com/docs/opentelemetry/configuration-options/aws-ecs-ec2-using-opentelemetry/
# Then update this endpoint to match (e.g. host networking collector, daemon
# service, or shared sidecar pattern).
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# OTEL endpoint discovery wrappers
# Each app container's entryPoint is overridden to:
#   1. read HostPrivateIPv4Address from $ECS_CONTAINER_METADATA_FILE
#      (file mounted by ECS agent because ECS_ENABLE_CONTAINER_METADATA=true)
#   2. export OTEL_EXPORTER_OTLP_ENDPOINT pointing at that IP, port 4318
#   3. exec the original container CMD
# The Coralogix OTEL daemon collector listens on the EC2 host's primary IP
# (host networking), reachable from awsvpc-mode tasks via the host's
# private IP only - not localhost, not the task ENI IP.
# -----------------------------------------------------------------------------
locals {
  otel_wrapper_alpine = <<-EOT
    IP=$(sed -n 's/.*"HostPrivateIPv4Address"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$${ECS_CONTAINER_METADATA_FILE}")
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://$${IP}:4318"
    echo "OTEL endpoint set to $${OTEL_EXPORTER_OTLP_ENDPOINT}"
    exec "$@"
  EOT

  otel_wrapper_python = <<-EOT
    IP=$(python3 -c "import json,os; print(json.load(open(os.environ['ECS_CONTAINER_METADATA_FILE']))['HostPrivateIPv4Address'])")
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://$${IP}:4318"
    echo "OTEL endpoint set to $${OTEL_EXPORTER_OTLP_ENDPOINT}"
    exec "$@"
  EOT
}

locals {
  common_otel_env = [
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4318" },
    { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
    { name = "OTEL_RESOURCE_ATTRIBUTES", value = "service.namespace=petstore,service.version=1.0.0,deployment.environment=aws-ecs" },
    { name = "OTEL_LOGS_EXPORTER", value = "otlp" },
    { name = "OTEL_TRACES_EXPORTER", value = "otlp" },
    { name = "OTEL_METRICS_EXPORTER", value = "otlp" },
  ]
}

# =============================================================================
# CATALOG SERVICE (Node)
# =============================================================================
locals {
  catalog_container = {
    name      = "catalog-service"
    image     = "${local.ecr_repository_urls["catalog-service"]}:latest"
    cpu       = 128
    memory    = 512
    essential = true
    entryPoint = ["sh", "-c", local.otel_wrapper_alpine, "--"]
    command = ["node", "index.js"]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:3001/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    environment = concat(local.common_otel_env, [
      { name = "OTEL_SERVICE_NAME", value = "catalog-service" },
      { name = "PORT", value = "3001" },
      { name = "DB_HOST", value = "postgres.petstore.local" },
      { name = "DB_USER", value = "petstore" },
      { name = "DB_PASSWORD", value = "petstore" },
      { name = "DB_NAME", value = "petstore" },
      { name = "NODE_OPTIONS", value = "--require @opentelemetry/auto-instrumentations-node/register" },
    ])

    portMappings = [{ containerPort = 3001, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "catalog-service"
      }
    }
  }
}

resource "aws_ecs_task_definition" "catalog_service" {
  family                   = "${var.project_prefix}-catalog-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256  # 256 app + 128 collector
  memory                   = 768  # 512 app + 256 collector
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([local.catalog_container])
}

# =============================================================================
# PAYMENTS SERVICE (Go)
# =============================================================================
locals {
  payments_container = {
    name      = "payments-service"
    image     = "${local.ecr_repository_urls["payments-service"]}:latest"
    cpu       = 128
    memory    = 512
    essential = true
    entryPoint = ["sh", "-c", local.otel_wrapper_alpine, "--"]
    command = ["./payments-service"]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    environment = concat(local.common_otel_env, [
      { name = "OTEL_SERVICE_NAME", value = "payments-service" },
      { name = "PORT", value = "8080" },
      { name = "FAILURE_RATE", value = "0.10" },
      { name = "MAX_LATENCY_MS", value = "800" },
    ])

    portMappings = [{ containerPort = 8080, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "payments-service"
      }
    }
  }
}

resource "aws_ecs_task_definition" "payments_service" {
  family                   = "${var.project_prefix}-payments-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 768
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([local.payments_container])
}

# =============================================================================
# ORDERS SERVICE (Python)
# =============================================================================
locals {
  orders_container = {
    name      = "orders-service"
    image     = "${local.ecr_repository_urls["orders-service"]}:latest"
    cpu       = 128
    memory    = 512
    essential = true
    entryPoint = ["sh", "-c", local.otel_wrapper_python, "--"]
    command = ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
    healthCheck = {
      command     = ["CMD-SHELL", "python3 -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8001/health').status==200 else 1)\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    environment = concat(local.common_otel_env, [
      { name = "OTEL_SERVICE_NAME", value = "orders-service" },
      { name = "DB_HOST", value = "postgres.petstore.local" },
      { name = "DB_USER", value = "petstore" },
      { name = "DB_PASSWORD", value = "petstore" },
      { name = "DB_NAME", value = "petstore" },
      { name = "CATALOG_URL", value = "http://catalog-service.petstore.local:3001" },
      { name = "PAYMENTS_URL", value = "http://payments-service.petstore.local:8080" },
      { name = "OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED", value = "true" },
    ])

    portMappings = [{ containerPort = 8001, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "orders-service"
      }
    }
  }
}

resource "aws_ecs_task_definition" "orders_service" {
  family                   = "${var.project_prefix}-orders-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 768
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([local.orders_container])
}

# =============================================================================
# API GATEWAY (Python)
# =============================================================================
locals {
  api_gateway_container = {
    name      = "api-gateway"
    image     = "${local.ecr_repository_urls["api-gateway"]}:latest"
    cpu       = 128
    memory    = 512
    essential = true
    entryPoint = ["sh", "-c", local.otel_wrapper_python, "--"]
    command = ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
    healthCheck = {
      command     = ["CMD-SHELL", "python3 -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health').status==200 else 1)\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    environment = concat(local.common_otel_env, [
      { name = "OTEL_SERVICE_NAME", value = "api-gateway" },
      { name = "CATALOG_URL", value = "http://catalog-service.petstore.local:3001" },
      { name = "ORDERS_URL", value = "http://orders-service.petstore.local:8001" },
      { name = "OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED", value = "true" },
    ])

    portMappings = [{ containerPort = 8000, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api-gateway"
      }
    }
  }
}

resource "aws_ecs_task_definition" "api_gateway" {
  family                   = "${var.project_prefix}-api-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 768
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([local.api_gateway_container])
}

# =============================================================================
# FRONTEND (Node)
# =============================================================================
locals {
  frontend_container = {
    name      = "frontend"
    image     = "${local.ecr_repository_urls["frontend"]}:latest"
    cpu       = 128
    memory    = 512
    essential = true
    entryPoint = ["sh", "-c", local.otel_wrapper_alpine, "--"]
    command = ["node", "index.js"]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    environment = concat(local.common_otel_env, [
      { name = "OTEL_SERVICE_NAME", value = "frontend" },
      { name = "API_GATEWAY_URL", value = "http://api-gateway.petstore.local:8000" },
      { name = "NODE_OPTIONS", value = "--require @opentelemetry/auto-instrumentations-node/register" },
    ])

    portMappings = [{ containerPort = 3000, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "frontend"
      }
    }
  }
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.project_prefix}-frontend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 768
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([local.frontend_container])
}
