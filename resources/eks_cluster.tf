# EKS Cluster using official module v21.0
module "eks_al2023" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.eks_name
  kubernetes_version = var.cluster_version

  # VPC Configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Addons
  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    livekit_nodes = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size = 2
      max_size = 5
      # This value is ignored after the initial creation
      # https://github.com/bryantbiggs/eks-desired-size-hack
      desired_size = 3

      # This is not required - demonstrates how to pass additional configuration to nodeadm
      # Ref https://awslabs.github.io/amazon-eks-ami/nodeadm/doc/api/
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                shutdownGracePeriod: 30s
        EOT
      }]
    }
  }

  # Enable cluster creator admin permissions (default behavior)
  enable_cluster_creator_admin_permissions = true

  tags = local.tags
}