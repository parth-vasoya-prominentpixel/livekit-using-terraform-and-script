################################################################################
# VPC Outputs
################################################################################

output "vpc_id" {
  description = "ID of the VPC where resources are created"
  value       = module.vpc.vpc_id
}

output "vpc_arn" {
  description = "The ARN of the VPC"
  value       = module.vpc.vpc_arn
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "nat_gateway_ids" {
  description = "List of IDs of the NAT Gateways"
  value       = module.vpc.natgw_ids
}

output "internet_gateway_id" {
  description = "The ID of the Internet Gateway"
  value       = module.vpc.igw_id
}

################################################################################
# EKS Cluster Outputs
################################################################################

output "cluster_arn" {
  description = "The Amazon Resource Name (ARN) of the cluster"
  value       = module.eks_al2023.cluster_arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks_al2023.cluster_certificate_authority_data
}

output "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  value       = module.eks_al2023.cluster_endpoint
}

output "cluster_id" {
  description = "The ID of the EKS cluster"
  value       = module.eks_al2023.cluster_id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks_al2023.cluster_name
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  value       = module.eks_al2023.cluster_oidc_issuer_url
}

output "cluster_version" {
  description = "The Kubernetes version for the EKS cluster"
  value       = module.eks_al2023.cluster_version
}

output "cluster_platform_version" {
  description = "Platform version for the EKS cluster"
  value       = module.eks_al2023.cluster_platform_version
}

output "cluster_status" {
  description = "Status of the EKS cluster"
  value       = module.eks_al2023.cluster_status
}

output "cluster_primary_security_group_id" {
  description = "Cluster security group that was created by Amazon EKS for the cluster"
  value       = module.eks_al2023.cluster_primary_security_group_id
}

################################################################################
# EKS Identity Provider
################################################################################

output "oidc_provider" {
  description = "The OpenID Connect identity provider (issuer URL without leading `https://`)"
  value       = module.eks_al2023.oidc_provider
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC Provider"
  value       = module.eks_al2023.oidc_provider_arn
}

################################################################################
# EKS Addons
################################################################################

output "cluster_addons" {
  description = "Map of attribute maps for all EKS cluster addons enabled"
  value       = module.eks_al2023.cluster_addons
}

################################################################################
# EKS Managed Node Group
################################################################################

output "eks_managed_node_groups" {
  description = "Map of attribute maps for all EKS managed node groups created"
  value       = module.eks_al2023.eks_managed_node_groups
}

output "eks_managed_node_groups_autoscaling_group_names" {
  description = "List of the autoscaling group names created by EKS managed node groups"
  value       = module.eks_al2023.eks_managed_node_groups_autoscaling_group_names
}

################################################################################
# ElastiCache Redis Outputs
################################################################################

output "redis_cluster_arn" {
  description = "ARN of the ElastiCache replication group"
  value       = module.redis.replication_group_arn
}

output "redis_cluster_endpoint" {
  description = "Primary endpoint address of the Redis cluster"
  value       = module.redis.replication_group_primary_endpoint_address != null ? "${module.redis.replication_group_primary_endpoint_address}:6379" : ""
}

output "redis_cluster_id" {
  description = "ID of the ElastiCache replication group"
  value       = module.redis.replication_group_id
}

output "redis_cluster_port" {
  description = "Port number on which the configuration endpoint will accept connections"
  value       = module.redis.replication_group_port
}

################################################################################
# Security Group Outputs
################################################################################

output "sip_security_group_id" {
  description = "Security group ID for SIP traffic"
  value       = aws_security_group.sip_traffic.id
}

################################################################################
# Useful Commands Outputs
################################################################################

output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks_al2023.cluster_name}"
}

################################################################################
# LiveKit Configuration Outputs
################################################################################

output "livekit_redis_config" {
  description = "Redis configuration for LiveKit values.yaml"
  value = {
    address = "${module.redis.replication_group_primary_endpoint_address}:6379"
  }
}

output "deployment_summary" {
  description = "Summary of deployed resources"
  value = {
    cluster_name     = module.eks_al2023.cluster_name
    cluster_endpoint = module.eks_al2023.cluster_endpoint
    redis_endpoint   = "${coalesce(module.redis.replication_group_configuration_endpoint_address, module.redis.replication_group_primary_endpoint_address, "localhost")}:6379"
    vpc_id          = module.vpc.vpc_id
    region          = var.region
    environment     = var.env
  }
}