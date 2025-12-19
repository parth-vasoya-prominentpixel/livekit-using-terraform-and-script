# EKS Cluster with managed node groups - Using stable version
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  name               = local.cluster_name
  kubernetes_version = var.cluster_version

  # EKS Addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    livekit_nodes = {
      # Using Amazon Linux 2 (standard Linux/UNIX)
      instance_types = ["t3.medium"]
      ami_type       = "AL2_x86_64"
      
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

      # Security configuration
      metadata_options = {
        http_endpoint = "enabled"
        http_tokens   = "required"
        http_put_response_hop_limit = 2
      }
    }
  }

  tags = local.tags
}