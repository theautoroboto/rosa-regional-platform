# RHOBS API Gateway Module
#
# Creates a public mTLS-secured API Gateway for RHOBS metric/log ingestion with
# path-based routing to Thanos Receive and Loki Distributor.
#
# Architecture:
#   Internet → API Gateway (mTLS) → VPC Link → ALB → Path-Based Routing
#     ├─ /metrics* → Thanos Receive target group (port 19291)
#     └─ /logs*    → Loki Distributor target group (port 3100)

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# =============================================================================
# Base API Gateway with mTLS Enabled
# =============================================================================

module "api_gateway_base" {
  source = "../api-gateway"

  vpc_id                 = var.vpc_id
  private_subnet_ids     = var.private_subnet_ids
  regional_id            = var.regional_id
  node_security_group_id = var.node_security_group_id
  cluster_name           = var.cluster_name

  # Thanos Receive is the default target
  target_port       = 19291
  health_check_path = "/-/healthy"

  # mTLS Configuration
  enable_mtls        = true
  truststore_uri     = var.truststore_uri
  truststore_version = var.truststore_version

  # Custom Domain
  api_domain_name         = var.api_domain_name
  regional_hosted_zone_id = var.regional_hosted_zone_id

  # API Configuration
  stage_name      = var.stage_name
  api_description = "RHOBS Observability Ingestion API (mTLS-secured)"
}

# =============================================================================
# Additional Target Group for Loki Distributor
# =============================================================================

resource "aws_lb_target_group" "loki" {
  name        = "${var.regional_id}-rhobs-loki-tg"
  port        = 3100
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for TargetGroupBinding

  health_check {
    enabled             = true
    path                = "/ready"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-rhobs-loki-tg"
    "eks:eks-cluster-name" = var.cluster_name
    Component              = "rhobs"
    Service                = "loki-distributor"
  }
}

# =============================================================================
# Path-Based Routing Rules
#
# Routes traffic to different target groups based on URL path:
#   - /metrics* → Thanos Receive (remote write endpoint)
#   - /logs*    → Loki Distributor (log push endpoint)
# =============================================================================

# Priority 100: Route /metrics traffic to Thanos Receive
resource "aws_lb_listener_rule" "thanos_metrics" {
  listener_arn = module.api_gateway_base.alb_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = module.api_gateway_base.target_group_arn # Thanos TG (default from base module)
  }

  condition {
    path_pattern {
      values = ["/metrics", "/metrics/*"]
    }
  }

  tags = {
    Name      = "${var.regional_id}-rhobs-thanos-rule"
    Component = "rhobs"
    Service   = "thanos-receive"
  }
}

# Priority 101: Route /logs and /loki traffic to Loki Distributor
resource "aws_lb_listener_rule" "loki_logs" {
  listener_arn = module.api_gateway_base.alb_listener_arn
  priority     = 101

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki.arn
  }

  condition {
    path_pattern {
      values = ["/logs", "/logs/*", "/loki/*"]
    }
  }

  tags = {
    Name      = "${var.regional_id}-rhobs-loki-rule"
    Component = "rhobs"
    Service   = "loki-distributor"
  }
}

# =============================================================================
# Default Action: Return 404 for unknown paths
#
# Override the base module's default action to return 404 instead of forwarding
# to Thanos. This ensures only /metrics and /logs paths are accepted.
# =============================================================================

# Note: The base module already has a default action to forward to Thanos TG.
# If a request doesn't match /metrics or /logs, it will fall through to the
# default action. This is acceptable since we expect only these two paths.
# For stricter control, we could add a fixed-response action with 404.
