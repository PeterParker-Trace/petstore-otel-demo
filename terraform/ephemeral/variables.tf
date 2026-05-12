# =============================================================================
# ephemeral/variables.tf
# =============================================================================

variable "aws_region" {
  description = "AWS region (must match persistent stack)"
  type        = string
  default     = "eu-north-1"
}

variable "owner" {
  description = "Tag value for the Owner tag"
  type        = string
}

variable "project_prefix" {
  description = "Prefix used for resource names"
  type        = string
  default     = "petstore-otel-demo"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for ECS hosts (must be ARM/Graviton)"
  type        = string
  default     = "m6g.large"
}

variable "asg_desired_capacity" {
  description = "Number of EC2 instances in the ASG"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Max number of EC2 instances (in case ASG needs to scale during deploys)"
  type        = number
  default     = 2
}
