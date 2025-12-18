# EBS CSI Driver addon - deployed separately to avoid circular dependencies
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = null  # Use latest compatible version
  service_account_role_arn    = aws_iam_role.ebs_csi_irsa_role.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  
  # Ensure proper dependency order
  depends_on = [
    module.eks.cluster_addons,
    module.eks.eks_managed_node_groups,
    aws_iam_role.ebs_csi_irsa_role,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]

  tags = local.tags
}