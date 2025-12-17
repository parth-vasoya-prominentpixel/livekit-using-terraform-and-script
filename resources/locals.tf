locals {
  # Region prefixes for consistent naming
  region_prefixes = {
    us-east-1      = "use1"
    us-east-2      = "use2"
    us-west-1      = "usw1"
    us-west-2      = "usw2"
    eu-west-1      = "euw1"
    eu-west-2      = "euw2"
    eu-central-1   = "euc1"
    ap-southeast-1 = "apse1"
    ap-southeast-2 = "apse2"
  }

  # Common tags for all resources
  tags = {
    company    = var.company
    env        = var.env
    created_by = "Terraform"
    region     = var.region
    project    = "LiveKit-EKS"
  }

  # Naming convention: <company-prefix>-<servicename>-<custom-name>-<region-prefix>-<env>
  region_prefix = local.region_prefixes[var.region]
  
  # Service name mappings (max 4 letters)
  service_names = {
    vpc         = "vpc"
    eks         = "eks"
    elasticache = "ec"    # ElastiCache service
    rds         = "rds"   # RDS database service
    ec2         = "ec2"
    iam         = "iam"
    kms         = "kms"
    sg          = "sg"    # security group
    s3          = "s3"
    lambda      = "lmbd"  # Lambda function
    alb         = "alb"   # Application Load Balancer
    nlb         = "nlb"   # Network Load Balancer
  }

  # Base naming function
  base_name_prefix = "${var.prefix_company}-${local.region_prefix}-${var.env}"
  
  # Service-specific naming
  vpc_name           = "${var.prefix_company}-${local.service_names.vpc}-main-${local.region_prefix}-${var.env}"
  eks_name           = "${var.prefix_company}-${local.service_names.eks}-${var.cluster_name}-${local.region_prefix}-${var.env}"
  elasticache_name   = "${var.prefix_company}-${local.service_names.elasticache}-redis-${local.region_prefix}-${var.env}"
  
  # Additional resource naming helpers
  iam_role_prefix = "${var.prefix_company}-${local.service_names.iam}"
  kms_alias_name  = "${var.prefix_company}-${local.service_names.kms}-${var.cluster_name}-${local.region_prefix}-${var.env}"
  sg_name_prefix  = "${var.prefix_company}-${local.service_names.sg}"
  
  # Legacy support for existing references
  name_prefix  = local.base_name_prefix
  cluster_name = local.eks_name
  redis_name   = local.elasticache_name  # For backward compatibility

  # VPC and subnet configuration (using new VPC)
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets
  public_subnet_ids  = module.vpc.public_subnets
  subnet_ids         = module.vpc.private_subnets
}
