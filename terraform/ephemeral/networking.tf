# =============================================================================
# ephemeral/networking.tf - Chunk B1
#
# VPC + 2 public subnets (in different AZs for resilience) + IGW + route table
# + 3 security groups (ALB, ECS tasks, Postgres).
# =============================================================================

# -----------------------------------------------------------------------------
# VPC - the logical network for all our resources
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # required for service discovery via Cloud Map later
  enable_dns_hostnames = true # gives instances DNS names like ip-10-0-1-23.eu-north-1.compute.internal

  tags = {
    Name = "${var.project_prefix}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway - the door between our VPC and the public internet
# -----------------------------------------------------------------------------
# Without this, nothing in the VPC can reach the internet (or vice versa).
# An IGW is attached to one VPC and is free.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_prefix}-igw"
  }
}

# -----------------------------------------------------------------------------
# Public subnets - one per AZ for HA
# -----------------------------------------------------------------------------
# We slice the VPC's /16 into smaller /24 blocks. Each subnet lives in one AZ.
# "Public" means tasks here get public IPs (via map_public_ip_on_launch) and
# the subnet's route table sends traffic to the IGW.
resource "aws_subnet" "public" {
  count                   = 2 # one per AZ
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  # cidrsubnet(10.0.0.0/16, 8, 1) -> 10.0.1.0/24
  # cidrsubnet(10.0.0.0/16, 8, 2) -> 10.0.2.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # auto-assigns public IPs to launched instances

  tags = {
    Name = "${var.project_prefix}-public-${count.index + 1}"
    Tier = "public"
  }
}

# -----------------------------------------------------------------------------
# Route table - defines where outbound traffic goes
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # Default route: anything not VPC-local goes to the Internet Gateway.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_prefix}-public-rt"
  }
}

# Associate the route table with both public subnets so they actually use it.
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------
# Three layers of network security:
#   1. ALB SG       - only thing internet talks to
#   2. ECS Tasks SG - only accept traffic from ALB SG (for frontend) or from
#                     other ECS tasks (for internal microservice traffic)
#   3. Postgres SG  - only accept traffic from ECS Tasks SG
#
# IMPORTANT: AWS Security Group descriptions must be plain ASCII. Avoid em dashes,
# smart quotes, and other Unicode in descriptions or AWS returns InvalidParameterValue.

# --- ALB Security Group ---
resource "aws_security_group" "alb" {
  name        = "${var.project_prefix}-alb-sg"
  description = "Public HTTP traffic to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (so ALB can reach targets)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-alb-sg"
  }
}

# --- ECS Tasks Security Group ---
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_prefix}-ecs-tasks-sg"
  description = "ECS task traffic from ALB on app ports and internal task-to-task"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound (tasks need to reach ECR, Secrets Manager, Coralogix, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-ecs-tasks-sg"
  }
}

# Allow inbound on port 3000 (frontend) from ALB.
resource "aws_security_group_rule" "ecs_tasks_from_alb" {
  type                     = "ingress"
  description              = "HTTP from ALB to frontend container"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_tasks.id
  source_security_group_id = aws_security_group.alb.id
}

# Allow internal task-to-task traffic on all ports.
# This is a "self-reference": any task with this SG can reach any other task with this SG.
# In production you'd narrow this to specific ports, but for our demo all our internal
# service ports (8000, 8001, 3001, 8080, 5432) fall under this rule.
resource "aws_security_group_rule" "ecs_tasks_self" {
  type                     = "ingress"
  description              = "Allow all internal traffic between ECS tasks"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_tasks.id
  source_security_group_id = aws_security_group.ecs_tasks.id
}

# --- Postgres Security Group ---
# Separate SG even though Postgres runs in an ECS task. This lets us reference
# it cleanly in the Postgres task definition later, and matches the pattern
# you would use if Postgres were RDS.
resource "aws_security_group" "postgres" {
  name        = "${var.project_prefix}-postgres-sg"
  description = "Postgres - only from ECS tasks"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-postgres-sg"
  }
}

resource "aws_security_group_rule" "postgres_from_ecs" {
  type                     = "ingress"
  description              = "Postgres from ECS tasks"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.postgres.id
  source_security_group_id = aws_security_group.ecs_tasks.id
}
