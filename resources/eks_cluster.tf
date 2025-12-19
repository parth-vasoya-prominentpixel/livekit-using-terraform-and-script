# EKS Cluster with managed node groups - Latest version v21.0
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.cluster_version

  # EKS Addons - New format for v21.0
  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = {}
  }

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # EKS Managed Node Groups - Based on official example
  eks_managed_node_groups = {
    livekit_nodes = {
      # Using AL2023 for Kubernetes 1.34
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      
      min_size = 1
      max_size = 10
      # This value is ignored after initial creation
      desired_size = 3

      # Attach SIP security group for Twilio traffic
      vpc_security_group_ids = [aws_security_group.sip_traffic.id]

      # Labels for cluster autoscaler
      labels = {
        "cluster-autoscaler/enabled" = "true"
        "cluster-autoscaler/cluster" = local.cluster_name
        "node-type"                  = "livekit-worker"
      }

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

  tags = local.tags
}