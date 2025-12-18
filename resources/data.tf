# Get current AWS caller identity
data "aws_caller_identity" "current" {}

# Get current user identity (extract user ARN from assumed role if needed)
locals {
  # Extract the actual user ARN from assumed role ARN if present
  current_user_arn = can(regex("assumed-role", data.aws_caller_identity.current.arn)) ? (
    # If it's an assumed role, extract the role ARN
    replace(data.aws_caller_identity.current.arn, "/assumed-role/([^/]+)/.*", "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/$1")
  ) : data.aws_caller_identity.current.arn
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# AWS managed IAM policies
data "aws_iam_policy" "eks_cluster_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy" "eks_worker_node_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

data "aws_iam_policy" "eks_cni_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

data "aws_iam_policy" "eks_container_registry_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}