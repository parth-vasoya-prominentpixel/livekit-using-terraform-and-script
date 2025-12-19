# EKS Access Entry for GitHub Actions OIDC Role
# This is created separately to avoid conflicts with the EKS module

resource "aws_eks_access_entry" "github_actions_role" {
  count = var.deployment_role_arn != "" ? 1 : 0
  
  cluster_name      = module.eks_al2023.cluster_name
  principal_arn     = var.deployment_role_arn
  type             = "STANDARD"
  
  depends_on = [module.eks_al2023]
  
  tags = merge(local.tags, {
    Name = "${local.eks_name}-github-actions-access"
  })
}

# Associate the access entry with cluster admin policy
resource "aws_eks_access_policy_association" "github_actions_admin" {
  count = var.deployment_role_arn != "" ? 1 : 0
  
  cluster_name  = module.eks_al2023.cluster_name
  principal_arn = var.deployment_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  
  access_scope {
    type = "cluster"
  }
  
  depends_on = [aws_eks_access_entry.github_actions_role]
}

# Output the access entry information
output "github_actions_access_entry" {
  description = "GitHub Actions role access entry details"
  value = var.deployment_role_arn != "" ? {
    principal_arn = var.deployment_role_arn
    cluster_name  = module.eks_al2023.cluster_name
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    access_scope  = "cluster"
  } : null
}