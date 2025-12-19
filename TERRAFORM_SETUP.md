# LiveKit EKS Infrastructure - Terraform Setup

## Overview
This infrastructure uses **Terraform** with official AWS modules to deploy a complete LiveKit environment on EKS.

## Architecture

### Infrastructure Components
1. **VPC** - Custom VPC with public/private subnets
2. **EKS Cluster** - Kubernetes 1.34 with AL2023 managed nodes
3. **ElastiCache Redis** - Session storage for LiveKit
4. **Security Groups** - SIP traffic restricted to Twilio CIDRs
5. **Load Balancer Controller** - AWS ALB/NLB integration
6. **LiveKit** - Video conferencing application

## Terraform Modules Used

### VPC Module (v5.0)
```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
}
```

### EKS Module (v21.0)
```hcl
module "eks_al2023" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"
  
  cluster_version = "1.34"
  
  # EKS Addons
  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
  }
  
  # Managed Node Group
  eks_managed_node_groups = {
    livekit_nodes = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 2
      max_size       = 5
      desired_size   = 3
    }
  }
}
```

### ElastiCache Module (v1.0)
```hcl
module "redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.0"
  
  engine_version     = "7.0"
  node_type          = "cache.t3.micro"
  num_cache_clusters = 1
}
```

## Deployment Pipeline

### Step-by-Step Manual Approval Process

#### Step 1: Deploy VPC & EKS Cluster
- Creates VPC with NAT Gateway
- Deploys EKS 1.34 cluster
- 3 managed nodes (t3.medium, AL2023)
- EKS addons (CoreDNS, VPC-CNI, Kube-proxy, Pod Identity Agent)
- ElastiCache Redis
- SIP Security Group
- **Time**: ~15-20 minutes

#### Step 2: Verify Redis
- Verifies Redis cluster is ready
- Gets Redis endpoint for LiveKit
- **Time**: ~2-3 minutes

#### Step 3: Setup Load Balancer Controller
- Installs AWS Load Balancer Controller
- Creates IAM service account with OIDC
- **Time**: ~3-5 minutes

#### Step 4: Deploy LiveKit
- Deploys LiveKit via Helm
- Connects to Redis
- **Time**: ~5-10 minutes

## Key Features

### EKS Configuration
- **Kubernetes Version**: 1.34 (latest, no extended support charges)
- **AMI Type**: AL2023_x86_64_STANDARD
- **Node Type**: t3.medium
- **Scaling**: 2-5 nodes (desired: 3)
- **Access Control**: EKS Access Entries (replaces aws-auth ConfigMap)

### Security
- **SIP Traffic**: Port 5060 (TCP/UDP) restricted to Twilio CIDRs only
- **Redis**: Encrypted at rest, accessible only from EKS cluster
- **VPC**: Private subnets for workloads, public subnets for load balancers

### Addons
- **CoreDNS**: DNS resolution
- **VPC-CNI**: Pod networking
- **Kube-proxy**: Service networking
- **Pod Identity Agent**: IAM roles for service accounts

## Configuration Files

### Main Terraform Files
- `vpc.tf` - VPC configuration
- `eks_cluster.tf` - EKS cluster and node groups
- `elasticache_redis.tf` - Redis cluster
- `security_groups.tf` - SIP security group
- `outputs.tf` - All resource outputs
- `variables.tf` - Input variables
- `locals.tf` - Local values and naming
- `data.tf` - Data sources
- `providers.tf` - AWS provider configuration

### Environment Configuration
- `environments/livekit-poc/us-east-1/dev/inputs.tfvars` - Variable values
- `environments/livekit-poc/us-east-1/dev/backend.tfvars` - S3 backend config

## Naming Convention

Format: `<prefix>-<service>-<name>-<region>-<env>`

Examples:
- VPC: `lp-vpc-main-use1-dev`
- EKS: `lp-eks-livekit-use1-dev`
- Redis: `lp-ec-redis-use1-dev`

## Destroy Process

The destroy job removes everything in reverse order:
1. Attempts to clean up LiveKit and Load Balancer (optional)
2. Runs `terraform destroy` to remove all infrastructure

**Note**: Terraform handles dependency order automatically.

## Manual Deployment (Local)

If you need to deploy manually:

```bash
# Navigate to resources directory
cd livekit-poc-infra/resources

# Initialize Terraform
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"

# Plan deployment
terraform plan \
  -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars" \
  -var="deployment_role_arn=<YOUR_ROLE_ARN>"

# Apply deployment
terraform apply \
  -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars" \
  -var="deployment_role_arn=<YOUR_ROLE_ARN>"

# Get outputs
terraform output
```

## Advantages of This Approach

1. **Single Source of Truth**: All infrastructure in Terraform
2. **Proper Dependencies**: Terraform manages resource dependencies
3. **Easy Destroy**: One command to remove everything
4. **State Management**: S3 backend for team collaboration
5. **Official Modules**: Well-maintained, tested modules
6. **Latest Versions**: EKS 1.34, AL2023, module v21.0
7. **Manual Control**: Step-by-step approval in pipeline

## Version Information

- **Terraform**: 1.10.3
- **EKS Module**: ~> 21.0
- **VPC Module**: ~> 5.0
- **ElastiCache Module**: ~> 1.0
- **Kubernetes**: 1.34
- **kubectl**: 1.30.0
- **Helm**: 3.16.3
