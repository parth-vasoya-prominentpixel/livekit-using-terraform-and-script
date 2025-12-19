# EKS Cluster - Correct arguments for terraform-aws-modules/eks/aws v20.x
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  
  cluster_endpoint_config = {
    public_access = true
  }
  
  enable_cluster_creator_admin_permissions = true

  # EKS Addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      before_compute = true
      most_recent    = true
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
      # Using AL2023 for Kubernetes 1.34
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      
      min_size     = 1
      max_size     = 10
      desired_size = 3

      # Attach SIP security group for Twilio traffic
      vpc_security_group_ids = [aws_security_group.sip_traffic.id]

      # Labels for cluster autoscaler
      labels = {
        "cluster-autoscaler/enabled" = "true"
        "cluster-autoscaler/cluster" = local.cluster_name
        "node-type"                  = "livekit-worker"
      }

      # AL2023 nodeadm configuration
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

  # Access entries to fix access issues
  access_entries = {
    # Current user/role access
    cluster_creator = {
      principal_arn = data.aws_caller_identity.current.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    
    # Deployment role access (if provided)
    deployment_role = var.deployment_role_arn != "" ? {
      principal_arn = var.deployment_role_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    } : null
  }

  tags = local.tags
}