###############################
# EKS Cluster Outputs
###############################

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = try(data.aws_eks_cluster.existing.name, local.cluster_info.cluster_name)
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = try(data.aws_eks_cluster.existing.endpoint, "")
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = try(local.cluster_info.cluster_security_group_id, "")
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN associated with EKS cluster"
  value       = try(data.aws_eks_cluster.existing.role_arn, "")
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = try(data.aws_eks_cluster.existing.certificate_authority[0].data, "")
}

output "cluster_version" {
  description = "The Kubernetes version for the EKS cluster"
  value       = try(data.aws_eks_cluster.existing.version, "1.34")
}

###############################
# EKS Node Groups Outputs
###############################

output "compute_config" {
  description = "EKS Auto Mode compute configuration"
  value = {
    enabled    = true
    node_pools = ["general-purpose"]
  }
}

###############################
# ElastiCache Redis Outputs
###############################

output "redis_cluster_id" {
  description = "ID of the ElastiCache Redis cluster"
  value       = module.redis.replication_group_id
}

output "redis_cluster_address" {
  description = "Address of the ElastiCache Redis cluster"
  value       = module.redis.replication_group_primary_endpoint_address
}

output "redis_cluster_port" {
  description = "Port of the ElastiCache Redis cluster"
  value       = 6379
}

output "redis_cluster_endpoint" {
  description = "Full Redis connection endpoint"
  value       = "${module.redis.replication_group_primary_endpoint_address}:6379"
}

###############################
# VPC Outputs
###############################

output "vpc_id" {
  description = "ID of the VPC"
  value       = local.vpc_id
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = local.private_subnet_ids
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = local.public_subnet_ids
}

output "subnet_ids" {
  description = "List of subnet IDs used by EKS"
  value       = local.subnet_ids
}

###############################
# Useful Commands Outputs
###############################

output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

###############################
# LiveKit Configuration Outputs
###############################

output "livekit_redis_config" {
  description = "Redis configuration for LiveKit values.yaml"
  value = {
    address = "${module.redis.replication_group_primary_endpoint_address}:6379"
  }
}

output "deployment_commands" {
  description = "Commands to deploy LiveKit after infrastructure is ready"
  value = {
    configure_kubectl = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
    create_namespace  = "kubectl create namespace livekit"
    set_context      = "kubectl config set-context --current --namespace=livekit"
    add_helm_repo    = "helm repo add livekit https://livekit.github.io/charts && helm repo update"
    deploy_livekit   = "helm upgrade --install livekit livekit/livekit -f DeploymentFile/livekit-values.yaml"
  }
}

output "deployment_summary" {
  description = "Summary of deployed resources"
  value = {
    cluster_name     = module.eks.cluster_name
    cluster_endpoint = module.eks.cluster_endpoint
    redis_endpoint   = "${module.redis.replication_group_primary_endpoint_address}:6379"
    vpc_id          = local.vpc_id
    region          = var.region
    environment     = var.env
  }
}

###############################
# IAM Roles and EKS Addons Outputs
###############################

output "cluster_configuration" {
  description = "EKS cluster configuration"
  value = {
    cluster_name       = module.eks.cluster_name
    kubernetes_version = var.cluster_version
    managed_nodes      = true
    node_groups_count  = length(module.eks.eks_managed_node_groups)
  }
}

output "cluster_addons_status" {
  description = "EKS cluster addons"
  value = {
    for addon_name, addon in module.eks.cluster_addons : addon_name => {
      addon_name    = addon.addon_name
      addon_version = addon.addon_version
      arn          = addon.arn
    }
  }
}



output "cluster_access_configuration" {
  description = "EKS cluster access configuration"
  value = {
    deployment_role_arn         = var.deployment_role_arn
    current_caller_arn          = data.aws_caller_identity.current.arn
    current_user_arn            = local.current_user_arn
    cluster_creator_permissions = true
    managed_node_groups        = true
  }
}

output "node_groups" {
  description = "EKS managed node groups"
  value = {
    for name, ng in module.eks.eks_managed_node_groups : name => {
      node_group_arn    = ng.node_group_arn
      node_group_id     = ng.node_group_id
      node_group_status = ng.node_group_status
    }
  }
}

output "cluster_security_groups" {
  description = "Security groups attached to the cluster"
  value = {
    cluster_security_group_id = module.eks.cluster_security_group_id
    sip_security_group_id     = aws_security_group.sip_traffic.id
  }
}