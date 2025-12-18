# LiveKit POC - EKS Infrastructure

Production-ready Terraform setup for LiveKit on AWS EKS with GitHub Actions CI/CD pipeline.

## What This Creates

- **New VPC**: Secure VPC with public/private subnets across 3 AZs
- **EKS Cluster**: Fully managed Kubernetes cluster (v1.31) in private subnets
- **Node Groups**: Auto-scaling worker nodes with cluster autoscaler support
- **ElastiCache Redis**: Redis cluster in private subnets for LiveKit session storage
- **Security Groups**: Port 5060 restricted to Twilio CIDRs only
- **Load Balancer Controller**: AWS Load Balancer Controller for ingress
- **EBS CSI Driver**: For persistent volume support
- **IRSA Roles**: IAM roles for service accounts with proper permissions

## Deployment Methods

### 🚀 GitHub Actions (Recommended)

The project includes a complete CI/CD pipeline with manual approval gates:

1. **Prerequisites**: Tool installation and validation
2. **Terraform Plan**: Review infrastructure changes
3. **Terraform Apply**: Deploy AWS infrastructure
4. **Load Balancer**: Setup AWS Load Balancer Controller
5. **LiveKit**: Deploy LiveKit application
6. **Destroy**: Clean up all resources (optional)

**To deploy:**
1. Push this repository to GitHub
2. Configure GitHub secrets (see [OIDC Setup](OIDC_SETUP.md))
3. Run the workflow: Actions → LiveKit EKS Manual Deployment Pipeline
4. Choose environment and step, then approve each stage

### 🛠️ Manual Deployment

For local development or testing:

```bash
# 1. Initialize Terraform
cd resources
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"

# 2. Plan deployment
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# 3. Deploy infrastructure
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# 4. Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev

# 5. Setup Load Balancer Controller
./scripts/02-setup-load-balancer.sh

# 6. Deploy LiveKit
./scripts/03-deploy-livekit.sh
```

## Configuration

### Required GitHub Secrets

For GitHub Actions deployment, configure these secrets:

- `AWS_OIDC_ROLE_ARN`: GitHub OIDC role ARN for AWS authentication
- `DEPLOYMENT_ROLE_ARN`: AWS deployment role ARN with necessary permissions

See [OIDC_SETUP.md](OIDC_SETUP.md) and [ROLE_SETUP.md](ROLE_SETUP.md) for detailed setup instructions.

### Configuration Files

**Backend Config** (`environments/livekit-poc/us-east-1/dev/backend.tfvars`):
```hcl
bucket = "livekit-poc-terraform-state-bucket"
key    = "livekit-poc/us-east-1/dev/eks-infrastructure/terraform.tfstate"
region = "us-east-1"
```

**Input Variables** (`environments/livekit-poc/us-east-1/dev/inputs.tfvars`):
```hcl
region         = "us-east-1"
env            = "dev"
prefix_company = "lp"
company        = "livekit-poc"

# EKS Configuration
cluster_name    = "livekit"
cluster_version = "1.31"

node_groups = {
  livekit_nodes = {
    instance_types = ["t3.medium"]
    min_size       = 1
    max_size       = 10
    desired_size   = 3
  }
}

# ElastiCache Redis
redis_node_type = "cache.t3.micro"

# Deployment role ARN
deployment_role_arn = "arn:aws:iam::ACCOUNT:role/lp-iam-resource-creation-role"
```

## Security Features

- **VPC Isolation**: Dedicated VPC with proper subnet segmentation
- **Private Deployment**: EKS nodes and Redis in private subnets only
- **SIP Security**: Port 5060 restricted to Twilio CIDR blocks only
- **IRSA**: IAM roles for service accounts with least privilege
- **Encryption**: Redis encryption at rest and in transit
- **IMDSv2**: Enforced on all EC2 instances
- **Network Security**: Security groups with minimal required access

## Accessing Your Deployment

After successful deployment:

```bash
# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev

# Check LiveKit pods
kubectl get pods -n livekit

# View LiveKit logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit -f

# Check ingress (ALB)
kubectl get ingress -n livekit
```

**LiveKit Access URL**: https://livekit-eks.digi-telephony.com

## Project Structure

```
├── .github/workflows/          # GitHub Actions CI/CD pipeline
├── environments/               # Environment-specific configurations
│   └── livekit-poc/us-east-1/dev/
├── resources/                  # Terraform infrastructure code
├── scripts/                    # Deployment and setup scripts
├── docs/                      # Documentation
│   └── archive/               # Archived documentation
├── DEPLOYMENT.md              # Detailed deployment guide
├── OIDC_SETUP.md             # GitHub OIDC configuration
├── ROLE_SETUP.md             # AWS IAM role setup
└── QUICK_REFERENCE.md        # Quick commands reference
```

## Troubleshooting

- **EBS CSI Driver Issues**: Check IRSA role permissions and node group status
- **Load Balancer Issues**: Verify AWS Load Balancer Controller deployment
- **Access Issues**: Ensure deployment role has proper EKS permissions
- **Networking Issues**: Check security groups and VPC configuration

For detailed troubleshooting, see the archived documentation in `docs/archive/`.

## Cost Optimization

**Estimated Monthly Costs (us-east-1)**:
- EKS Cluster: ~$72
- NAT Gateways (3x): ~$135
- ElastiCache Redis: ~$15
- EC2 Instances (3x t3.medium): ~$95
- **Total**: ~$317/month

**Cost Reduction Tips**:
- Use single NAT Gateway for dev environments
- Scale down node groups when not in use
- Use smaller instance types for testing