# EBS CSI Driver addon - deployed separately after IRSA and node groups are ready
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = null  # Use latest compatible version
  service_account_role_arn = aws_iam_role.ebs_csi_irsa_role.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  
  # Wait for IRSA role and node groups to be ready
  depends_on = [
    aws_iam_role.ebs_csi_irsa_role,
    aws_iam_role_policy_attachment.ebs_csi_policy,
    module.eks.eks_managed_node_groups,
    module.eks.cluster_addons
  ]

  tags = local.tags
}

# Create the EBS CSI service account manually to ensure proper RBAC
resource "kubernetes_service_account" "ebs_csi_controller" {
  metadata {
    name      = "ebs-csi-controller-sa"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ebs_csi_irsa_role.arn
    }
  }

  # Wait for cluster to be ready
  depends_on = [
    module.eks.cluster_addons,
    aws_iam_role.ebs_csi_irsa_role
  ]
}

# Create cluster role binding for EBS CSI controller
resource "kubernetes_cluster_role_binding" "ebs_csi_controller" {
  metadata {
    name = "ebs-csi-controller-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:controller:persistent-volume-binder"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ebs_csi_controller.metadata[0].name
    namespace = kubernetes_service_account.ebs_csi_controller.metadata[0].namespace
  }

  depends_on = [
    kubernetes_service_account.ebs_csi_controller
  ]
}