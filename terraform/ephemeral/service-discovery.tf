# =============================================================================
# ephemeral/service-discovery.tf - Chunk B3
#
# AWS Cloud Map provides DNS-based service discovery for ECS tasks.
#
# How it works:
#   1. We create a private DNS namespace (petstore.local) in our VPC.
#   2. We create a "service" entry for each microservice we'll deploy.
#   3. When ECS launches a task tied to one of these service entries, Cloud Map
#      automatically creates/updates an A record pointing to the task's IP.
#   4. Other tasks in the VPC can resolve "api-gateway.petstore.local" and get
#      the current IP of whatever task is running api-gateway.
#
# This replaces docker-compose's magic where service names just worked.
# =============================================================================

# -----------------------------------------------------------------------------
# Private DNS namespace - the "zone" all our service records live in
# -----------------------------------------------------------------------------
# Private means it's only resolvable from inside our VPC. The internet cannot
# see or query petstore.local - that's the whole point.
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "petstore.local"
  description = "Private DNS for petstore-otel-demo service discovery"
  vpc         = aws_vpc.main.id
}

# -----------------------------------------------------------------------------
# Cloud Map service entries - one per microservice
# -----------------------------------------------------------------------------
# These are like "templates" - when an ECS service is configured to use one,
# task IPs get auto-registered as A records under that service's DNS name.

locals {
  # Map of service name to the port the service listens on inside the container.
  # Used to keep service-discovery and task definitions consistent.
  services = {
    frontend         = 3000
    "api-gateway"    = 8000
    "catalog-service" = 3001
    "orders-service"  = 8001
    "payments-service" = 8080
    postgres          = 5432
  }
}

resource "aws_service_discovery_service" "service" {
  for_each = local.services

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    # Multiple A records under one name (one per task IP). If we ever scale to
    # multiple replicas, DNS round-robins across them.
    dns_records {
      ttl  = 10  # Short TTL means deregistered tasks drop out of DNS quickly
      type = "A"
    }

    # MULTIVALUE = round-robin DNS. WEIGHTED would be the alternative for
    # weighted routing, but multivalue is the standard choice for ECS.
    routing_policy = "MULTIVALUE"
  }

  # Cloud Map will refuse to delete the service if instances are registered.
  # force_destroy would be nice but it's not exposed - we rely on task deregistration.
  health_check_custom_config {
    failure_threshold = 1
  }
}
