# ElastiCache Redis using official module - for existing EKS cluster
module "redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.0"

  # Cluster configuration
  replication_group_id = "${local.cluster_info.cluster_name}-redis"
  description          = "Redis cluster for LiveKit session storage"

  # Node configuration
  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = "default.redis7"

  # Engine configuration
  engine_version     = "7.0"
  num_cache_clusters = 1

  # Network configuration - use existing VPC private subnets
  subnet_group_name = "${local.cluster_info.cluster_name}-redis-subnet-group"
  subnet_ids        = data.aws_subnets.private.ids
  vpc_id            = data.aws_vpc.existing.id

  # Security configuration
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # LiveKit doesn't support TLS for Redis

  # Backup configuration
  snapshot_retention_limit = 5
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "sun:05:00-sun:06:00"

  # Security group rules - only allow access from EKS cluster
  security_group_rules = {
    ingress_eks_cluster = {
      description                   = "Redis access from EKS cluster security group"
      type                         = "ingress"
      from_port                    = 6379
      to_port                      = 6379
      protocol                     = "tcp"
      referenced_security_group_id = local.cluster_info.cluster_security_group_id
    }
  }

  tags = local.tags
}
