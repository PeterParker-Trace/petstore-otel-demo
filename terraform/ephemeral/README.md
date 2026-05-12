# Ephemeral Terraform Stack

Short-lived AWS resources for running the petstore-otel-demo:

- VPC + public subnets in 2 AZs
- Internet Gateway, route tables, security groups
- ECS cluster with EC2 ASG on Spot (Graviton/ARM)
- Application Load Balancer
- Cloud Map service discovery
- Task definitions (each app + OTEL Collector sidecar)
- ECS services

**This stack is meant to be created and destroyed per session.** Don't leave it running 24/7.

## Prerequisites

1. `terraform/persistent` already applied (ECR repos exist, secret exists)
2. Coralogix secret value populated (see persistent stack README)
3. Docker images pushed to ECR (`./build-and-push.sh` from repo root)

## Usage

```bash
cd terraform/ephemeral

# First time setup
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to set your owner

# Initialize provider plugins
terraform init

# Plan and apply
terraform plan
terraform apply

# When done with the session, destroy everything
terraform destroy
```

## Cost while running

~$0.04-0.05/hour for:
- 1× m6g.large Spot EC2 instance
- ALB (always $0.025/hr)
- Data transfer (negligible at our load)

Destroyed: $0/hour.

## Chunks (incremental construction)

This stack is being built in incremental chunks:

- **B1: Networking** (this) — VPC, subnets, IGW, security groups
- **B2: ECS cluster + Postgres task** — cluster, ASG, Postgres ECS service
- **B3: ALB + service discovery** — Application Load Balancer + Cloud Map private DNS
- **B4: App services** — 5 task definitions and services with OTEL sidecars

Each chunk can be applied independently. After B4 is complete, this becomes a one-shot apply.
