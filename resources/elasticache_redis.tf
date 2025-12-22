# ElastiCache Redis using official module
module "redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.0"

  # Cluster configuration
  replication_group_id = "${local.elasticache_name}-redis"
  description          = "Redis cluster for LiveKit session storage"

  # Node configuration
  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = "default.redis7"

  # Engine configuration
  engine_version     = "7.0"
  num_cache_clusters = 1

  # Network configuration - use VPC private subnets
  subnet_group_name = "${local.elasticache_name}-redis-subnet-group"
  subnet_ids        = module.vpc.private_subnets
  vpc_id            = module.vpc.vpc_id

  # Security configuration
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # LiveKit doesn't support TLS for Redis

  # Backup configuration
  snapshot_retention_limit = 5
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "sun:05:00-sun:06:00"

  # Security group rules - allow access from EKS nodes and cluster
  security_group_rules = {
    ingress_eks_cluster = {
      description                   = "Redis access from EKS cluster security group"
      type                         = "ingress"
      from_port                    = 6379
      to_port                      = 6379
      protocol                     = "tcp"
      referenced_security_group_id = module.eks_al2023.cluster_security_group_id
    }
    ingress_eks_nodes = {
      description                   = "Redis access from EKS node security group"
      type                         = "ingress"
      from_port                    = 6379
      to_port                      = 6379
      protocol                     = "tcp"
      referenced_security_group_id = module.eks_al2023.node_security_group_id
    }
    ingress_private_subnets = {
      description = "Redis access from private subnets (EKS pods)"
      type        = "ingress"
      from_port   = 6379
      to_port     = 6379
      protocol    = "tcp"
      cidr_blocks = module.vpc.private_subnets_cidr_blocks
    }
  }

  tags = local.tags

  depends_on = [module.eks_al2023]
}
