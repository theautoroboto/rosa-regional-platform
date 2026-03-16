# =============================================================================
# ElastiCache Memcached Cluster for RHOBS Query Caching
#
# Provides caching layer for Thanos Query and Loki Query components
# to improve query performance and reduce load on storage backends
# =============================================================================

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "rhobs" {
  name       = "${var.regional_id}-rhobs-cache"
  subnet_ids = var.private_subnets

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-rhobs-cache-subnet-group"
      Component = "elasticache"
    }
  )
}

# Security Group for ElastiCache - only allow access from EKS cluster
resource "aws_security_group" "rhobs_cache" {
  name        = "${var.regional_id}-rhobs-cache"
  description = "Security group for RHOBS ElastiCache Memcached cluster"
  vpc_id      = var.vpc_id

  # Allow from EKS cluster additional security group
  ingress {
    description     = "Memcached from EKS cluster additional security group"
    from_port       = var.cache_port
    to_port         = var.cache_port
    protocol        = "tcp"
    security_groups = [var.eks_cluster_security_group_id]
  }

  # Allow from EKS cluster primary security group (used by Auto Mode nodes)
  ingress {
    description     = "Memcached from EKS cluster primary security group (Auto Mode)"
    from_port       = var.cache_port
    to_port         = var.cache_port
    protocol        = "tcp"
    security_groups = [var.eks_cluster_primary_security_group_id]
  }

  # Allow from bastion security group (if bastion is enabled)
  dynamic "ingress" {
    for_each = var.bastion_security_group_id != null ? [1] : []
    content {
      description     = "Memcached from bastion"
      from_port       = var.cache_port
      to_port         = var.cache_port
      protocol        = "tcp"
      security_groups = [var.bastion_security_group_id]
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-rhobs-cache-sg"
      Component = "elasticache"
    }
  )
}

# ElastiCache Memcached Cluster
resource "aws_elasticache_cluster" "rhobs" {
  cluster_id           = local.cache_cluster_id
  engine               = "memcached"
  engine_version       = var.cache_engine_version
  node_type            = var.cache_node_type
  num_cache_nodes      = var.cache_num_nodes
  parameter_group_name = var.cache_parameter_group_name
  port                 = var.cache_port
  subnet_group_name    = aws_elasticache_subnet_group.rhobs.name
  security_group_ids   = [aws_security_group.rhobs_cache.id]

  # Prefer AZ placement across available zones
  preferred_availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.cache_num_nodes, length(data.aws_availability_zones.available.names))
  )

  # Maintenance window
  maintenance_window = "mon:03:00-mon:04:00" # Monday 3-4 AM UTC

  # Notifications via SNS (optional, can be added later)
  # notification_topic_arn = var.sns_topic_arn

  tags = merge(
    local.common_tags,
    {
      Name      = local.cache_cluster_id
      Component = "elasticache"
      Purpose   = "RHOBS query caching"
    }
  )
}
