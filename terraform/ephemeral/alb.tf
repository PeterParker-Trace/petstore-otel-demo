# =============================================================================
# ephemeral/alb.tf - Chunk B3
#
# Public-facing Application Load Balancer (ALB) on port 80.
# Routes all traffic to the frontend service's target group.
#
# Structure:
#   ALB (load balancer)
#     |
#     |--> Listener on port 80 (defines what protocols/ports ALB accepts)
#     |       |
#     |       --> Default action: forward to Target Group
#     |
#     --> Target Group (the pool of healthy backend tasks)
#           Tasks register here when they start, deregister when they stop.
# =============================================================================

# -----------------------------------------------------------------------------
# The ALB itself
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project_prefix}-alb"
  internal           = false # public-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id # one per AZ

  # idle_timeout: how long ALB holds idle connections open.
  # Default is 60s; we keep it.
  idle_timeout = 60

  # Disable deletion protection. In production you'd enable this. For our
  # ephemeral demo we WANT terraform destroy to work cleanly.
  enable_deletion_protection = false
}

# -----------------------------------------------------------------------------
# Target Group - the pool of frontend tasks
# -----------------------------------------------------------------------------
# When ECS launches a frontend task, it gets registered here. ALB then sends
# traffic to that task. Health checks remove unhealthy tasks automatically.
resource "aws_lb_target_group" "frontend" {
  name        = "${var.project_prefix}-frontend"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # IMPORTANT: "ip" mode is required for awsvpc network mode (which we'll use in tasks)

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port" # whatever port the target registered with
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  # When a task drains, give it 30 seconds to finish in-flight requests before
  # ALB stops sending it new traffic. Default is 300 (5 min) which slows
  # deploys for no benefit in a demo.
  deregistration_delay = 30
}

# -----------------------------------------------------------------------------
# Listener - what protocol/port ALB accepts traffic on
# -----------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
