# =============================================================================
# ephemeral/ec2-asg.tf - Chunk B2
#
# EC2 Auto Scaling Group that provides compute capacity to ECS, running on
# Spot for cost optimization.
# =============================================================================

# -----------------------------------------------------------------------------
# Look up the latest ECS-optimized AMI for ARM64
# -----------------------------------------------------------------------------
# Amazon publishes ECS-optimized AMIs (Amazon Linux 2023 + Docker + ECS agent
# pre-installed) and stores the latest ID in SSM Parameter Store. By looking
# this up at apply time, we always get the current patched version - no
# hardcoded AMI IDs that go stale and trigger CVE alerts.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

# -----------------------------------------------------------------------------
# Launch Template - defines HOW each EC2 instance is launched
# -----------------------------------------------------------------------------
# Launch Template is the modern replacement for Launch Configurations. ASG
# uses it as a blueprint when scaling out.
resource "aws_launch_template" "ecs_node" {
  name_prefix   = "${var.project_prefix}-ecs-node-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  # Attach the instance profile so the ECS agent can register with the cluster.
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance.name
  }

  # Network setup: assign public IPs (we're using public subnets) and use
  # the ECS tasks SG. EC2 hosts share the SG with the tasks they run.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ecs_tasks.id]
  }

  # Spot configuration. interruption_behavior = "terminate" is the default and
  # works for our case. If you wanted longer-lived Spot, you'd use "stop"
  # with persistent requests, but that's overkill for a demo.
  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
    }
  }

  # user_data is a shell script that runs when the instance first boots.
  # We use it to tell the ECS agent which cluster to join.
  # base64encode is required because user_data is sent as base64 over the API.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
    # Enable container metadata in case we need it later
    echo "ECS_ENABLE_CONTAINER_METADATA=true" >> /etc/ecs/ecs.config
  EOT
  )

  # Tag the EC2 instance itself when it gets launched.
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_prefix}-ecs-node"
      Project     = "petstore-otel-demo"
      ManagedBy   = "terraform"
      Environment = "sandbox"
      Owner       = var.owner
      Stack       = "ephemeral"
    }
  }

  # Encrypt the root EBS volume. Best practice everywhere.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # Best practice: always replace launch template when content changes,
  # rather than trying to mutate it in place.
  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Auto Scaling Group - manages the EC2 instances
# -----------------------------------------------------------------------------
resource "aws_autoscaling_group" "ecs_nodes" {
  name                = "${var.project_prefix}-ecs-asg"
  vpc_zone_identifier = aws_subnet.public[*].id # spread across both public subnets

  min_size         = 1
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # Health checks: if an EC2 fails, replace it.
  # 300 seconds (5 min) grace period lets the instance fully boot and join ECS
  # before health checks start scoring it.
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs_node.id
    version = "$Latest"
  }

  # Critical: tells the ASG to NOT auto-terminate instances when they're
  # registered in an ECS Capacity Provider. The capacity provider controls
  # scaling decisions; ASG handles the actual machinery.
  protect_from_scale_in = false

  # Required for ECS capacity providers to manage this ASG.
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = false
  }

  # Standard tags
  tag {
    key                 = "Name"
    value               = "${var.project_prefix}-ecs-asg"
    propagate_at_launch = false
  }
  tag {
    key                 = "Project"
    value               = "petstore-otel-demo"
    propagate_at_launch = false
  }
  tag {
    key                 = "Owner"
    value               = var.owner
    propagate_at_launch = false
  }

  lifecycle {
    create_before_destroy = true
    # Don't fight Terraform vs ECS over desired_capacity. Both might try to
    # change it; ignore_changes lets ECS win.
    ignore_changes = [desired_capacity]
  }
}
