# ElastiCache Redis using official module
module "redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.0"

  # Cluster configuration
  replication_group_id = local.elasticache_name
  description          = "Redis cluster for LiveKit session storage"

  # Node configuration
  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = "default.redis7"

  # Engine configuration
  engine_version     = "7.0"
  num_cache_clusters = 1

  # Network configuration - use private subnets for security
  subnet_group_name = "${local.elasticache_name}-subnet-group"
  subnet_ids        = local.private_subnet_ids
  vpc_id            = local.vpc_id

  # Security configuration
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # LiveKit doesn't support TLS for Redis

  # Backup configuration
  snapshot_retention_limit = 5
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "sun:05:00-sun:06:00"

  # Security group rules - only allow access from EKS nodes
  security_group_rules = {
    ingress_eks_nodes = {
      description                   = "Redis access from EKS nodes only"
      type                         = "ingress"
      from_port                    = 6379
      to_port                      = 6379
      protocol                     = "tcp"
      referenced_security_group_id = module.eks.node_security_group_id
    }
    ingress_eks_cluster = {
      description                   = "Redis access from EKS cluster"
      type                         = "ingress"
      from_port                    = 6379
      to_port                      = 6379
      protocol                     = "tcp"
      referenced_security_group_id = module.eks.cluster_primary_security_group_id
    }
  }

  tags = local.tags
}
