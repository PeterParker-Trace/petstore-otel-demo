# =============================================================================
# ephemeral/iam.tf - Chunk B2
#
# Three distinct IAM roles for ECS, each serving a different job:
#
#   1. ec2_instance_role  - granted to the EC2 instance itself
#                           Lets the ECS agent register with the cluster
#
#   2. task_execution_role - granted to ECS at task startup
#                           Lets ECS pull images, fetch secrets, write logs
#
#   3. task_role          - granted to your app code while running
#                           For calling AWS APIs from inside the container
#
# Customers conflate these constantly. Each has a different "Principal" in its
# trust policy and a different set of attached permissions.
# =============================================================================

# -----------------------------------------------------------------------------
# Role 1: EC2 Instance Role - assumed by the EC2 service for our instances
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_instance" {
  name               = "${var.project_prefix}-ec2-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# AWS-managed policy that lets the ECS agent register/manage the instance.
resource "aws_iam_role_policy_attachment" "ec2_ecs" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Also attach SSM core so you can `aws ssm start-session` into the instance
# without SSH keys. Great for debugging - you can shell into ECS hosts via
# AWS Session Manager without opening port 22.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile = wrapper that lets an EC2 instance use an IAM role.
# IAM roles attach to "principals"; instance profiles attach to EC2 instances.
resource "aws_iam_instance_profile" "ec2_instance" {
  name = "${var.project_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name
}

# -----------------------------------------------------------------------------
# Role 2: Task Execution Role - assumed by ECS at task launch
# -----------------------------------------------------------------------------
# This is what ECS uses to set up the task: pull the image from ECR, fetch
# secrets from Secrets Manager, push logs to CloudWatch.
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.project_prefix}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# AWS-managed policy covering ECR pull + CloudWatch Logs write.
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom inline policy: lets ECS fetch our specific Coralogix secret.
# Scoped to ONLY the petstore-otel-demo/coralogix_private_key secret.
# This is intentional - principle of least privilege.
data "aws_iam_policy_document" "secrets_access" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.coralogix_secret_arn]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "secrets-access"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.secrets_access.json
}

# -----------------------------------------------------------------------------
# Role 3: Task Role - assumed by your application code at runtime
# -----------------------------------------------------------------------------
# Our apps don't call AWS APIs, so this role is intentionally minimal.
# Real apps would attach policies here to talk to S3, DynamoDB, etc.
resource "aws_iam_role" "task" {
  name               = "${var.project_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
