# EKS Cluster using official module with proper IAM setup
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  # VPC Configuration - using new VPC
  vpc_id                   = local.vpc_id
  subnet_ids               = local.subnet_ids
  control_plane_subnet_ids = local.private_subnet_ids

  # Cluster endpoint configuration (secure setup)
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # Restrict this in production

  # Enable cluster logging for security monitoring
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # EKS Addons (core addons only - EBS CSI added separately)
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
    # Note: aws-ebs-csi-driver added separately after IRSA setup
  }

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    for name, config in var.node_groups : name => {
      instance_types = config.instance_types
      min_size       = config.min_size
      max_size       = config.max_size
      desired_size   = config.desired_size

      # Use private subnets for security
      subnet_ids = local.private_subnet_ids

      # Enable cluster autoscaler (using custom labels, not reserved k8s.io prefix)
      labels = {
        "cluster-autoscaler/enabled" = "true"
        "cluster-autoscaler/cluster" = local.cluster_name
        "node-type"                  = "livekit-worker"
      }

      # Attach the SIP security group for Twilio traffic
      vpc_security_group_ids = [aws_security_group.sip_traffic.id]

      # Block metadata service v1 for security
      metadata_options = {
        http_endpoint = "enabled"
        http_tokens   = "required"
        http_put_response_hop_limit = 2
      }

      # Proper IAM configuration for node groups
      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }

  # Cluster access entries with proper permissions
  enable_cluster_creator_admin_permissions = true
  
  # Add access entries for deployment role and current user
  access_entries = merge(
    # Deployment role access (when provided)
    var.deployment_role_arn != "" ? {
      deployment_role = {
        kubernetes_groups = []
        principal_arn     = var.deployment_role_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    } : {},
    
    # Current AWS identity (for manual access)
    {
      current_user = {
        kubernetes_groups = []
        principal_arn     = data.aws_caller_identity.current.arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    }
  )

  tags = local.tags
}

# EBS CSI Driver IAM Role for Service Account (IRSA)
module "ebs_csi_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name             = "${local.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# AWS Load Balancer Controller IAM Role for Service Account (IRSA)
module "load_balancer_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${local.cluster_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

# Cluster Autoscaler IAM Role for Service Account (IRSA)
module "cluster_autoscaler_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                        = "${local.cluster_name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  tags = local.tags
}