# LiveKit POC - EKS Infrastructure

Simple and efficient Terraform setup for LiveKit on AWS EKS using official modules.

## What This Creates

- **New VPC**: Secure VPC with public/private subnets across 3 AZs
- **EKS Cluster**: Fully managed Kubernetes cluster (v1.31) in private subnets
- **Node Groups**: Auto-scaling worker nodes with cluster autoscaler support
- **Redis**: ElastiCache Redis in private subnets for LiveKit session storage
- **Security**: Port 5060 restricted to Twilio CIDRs only
- **NAT Gateways**: High availability with one NAT gateway per AZ
- **VPC Flow Logs**: Security monitoring enabled

## Prerequisites

- AWS CLI configured
- Terraform >= 1.0
- kubectl

## Quick Start

1. **Update Configuration**
   ```bash
   # Edit backend configuration
   cp environments/livekit-poc/us-east-1/dev/backend.tfvars.example environments/livekit-poc/us-east-1/dev/backend.tfvars
   # Update with your S3 bucket name
   
   # Edit inputs if needed
   vim environments/livekit-poc/us-east-1/dev/inputs.tfvars
   ```

2. **Deploy Infrastructure**
   ```bash
   make init
   make plan
   make apply
   ```

3. **Configure kubectl**
   ```bash
   make kubectl-config
   ```

## Configuration Files

### Backend Config (`backend.tfvars`)
```hcl
bucket = "your-terraform-state-bucket"
key    = "livekit-poc/us-east-1/dev/eks-infrastructure/terraform.tfstate"
region = "us-east-1"
```

### Input Variables (`inputs.tfvars`)
```hcl
region         = "us-east-1"
env            = "dev"

# VPC Configuration
vpc_cidr        = "10.0.0.0/16"
private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS Configuration
cluster_name    = "livekit-cluster"
cluster_version = "1.31"

node_groups = {
  livekit_nodes = {
    instance_types = ["t3.medium", "t3.large"]
    min_size       = 1
    max_size       = 10
    desired_size   = 2
  }
}

redis_node_type = "cache.t3.micro"
```

## Security Features

- **New VPC**: Isolated network environment with proper subnet segmentation
- **Private Subnets**: EKS nodes and Redis deployed in private subnets only
- **NAT Gateways**: Secure outbound internet access for private resources
- **Port 5060**: Only accessible from Twilio CIDR blocks
- **Redis**: Only accessible from EKS cluster nodes
- **VPC Flow Logs**: Network traffic monitoring for security analysis
- **IMDSv2**: Enforced on EC2 instances for enhanced security
- **Encryption**: Redis encryption at rest enabled

## Outputs

After deployment, get important values:
```bash
# Redis endpoint for LiveKit
terraform output redis_cluster_endpoint

# Cluster name
terraform output cluster_name

# kubectl config command
terraform output kubectl_config_command
```

## LiveKit Configuration

Use the Redis endpoint in your LiveKit values.yaml:
```yaml
livekit:
  redis:
    address: "<redis-endpoint-from-output>"
```

## Makefile Commands

```bash
make init     # Initialize Terraform
make plan     # Plan deployment
make apply    # Deploy infrastructure
make destroy  # Destroy infrastructure
make kubectl-config  # Configure kubectl
```

## Clean Architecture

- Uses official Terraform modules only
- No custom resources where modules exist
- Simple, maintainable configuration
- Follows AWS best practices