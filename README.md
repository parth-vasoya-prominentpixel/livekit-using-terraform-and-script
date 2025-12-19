# LiveKit EKS Infrastructure

Complete Terraform-based infrastructure for deploying LiveKit on Amazon EKS.

## 🏗️ Architecture

- **VPC**: Custom VPC with public/private subnets
- **EKS**: Kubernetes 1.34 cluster with AL2023 managed nodes
- **Redis**: ElastiCache Redis for session storage
- **Security**: SIP traffic restricted to Twilio CIDRs only
- **Load Balancer**: AWS Load Balancer Controller for ALB/NLB

## 📁 Project Structure

```
livekit-poc-infra/
├── .github/workflows/
│   └── livekit-pipeline.yml          # GitHub Actions pipeline
├── environments/
│   └── livekit-poc/us-east-1/dev/
│       ├── backend.tfvars             # S3 backend configuration
│       └── inputs.tfvars              # Environment variables
├── resources/
│   ├── vpc.tf                         # VPC module
│   ├── eks_cluster.tf                 # EKS module
│   ├── elasticache_redis.tf           # Redis module
│   ├── security_groups.tf             # Security groups
│   ├── outputs.tf                     # Terraform outputs
│   ├── variables.tf                   # Input variables
│   ├── locals.tf                      # Local values
│   ├── data.tf                        # Data sources
│   └── providers.tf                   # AWS provider
├── scripts/
│   ├── 00-prerequisites.sh            # Prerequisites check
│   ├── 02-setup-load-balancer.sh      # Load balancer setup
│   └── 03-deploy-livekit.sh           # LiveKit deployment
├── livekit-values.yaml                # LiveKit Helm values
└── README.md                          # This file
```

## 🚀 Deployment Pipeline

The GitHub Actions pipeline has **5 manual steps**:

### Step 1: Prerequisites ✅
- Verifies AWS credentials and permissions
- Checks required tools (Terraform, kubectl, Helm, eksctl)
- Validates S3 backend access
- **Time**: ~2-3 minutes

### Step 2: Terraform Plan 📋
- Runs `terraform plan` to show what will be created
- Saves plan for review
- **Time**: ~3-5 minutes

### Step 3: Terraform Apply 🚀
- Applies the Terraform plan
- Creates VPC, EKS cluster, Redis, security groups
- **Time**: ~15-20 minutes

### Step 4: Setup Load Balancer Controller ⚖️
- Installs AWS Load Balancer Controller
- Creates IAM service account with OIDC
- **Time**: ~3-5 minutes

### Step 5: Deploy LiveKit 🎥
- Deploys LiveKit via Helm
- Connects to Redis cluster
- **Time**: ~5-10 minutes

## 🔧 Manual Deployment

If you prefer to deploy manually:

```bash
# 1. Prerequisites
cd scripts
./00-prerequisites.sh

# 2. Terraform
cd ../resources
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# 3. Load Balancer Controller
cd ../scripts
CLUSTER_NAME=$(cd ../resources && terraform output -raw cluster_name) ./02-setup-load-balancer.sh

# 4. LiveKit
CLUSTER_NAME=$(cd ../resources && terraform output -raw cluster_name) \
REDIS_ENDPOINT=$(cd ../resources && terraform output -raw redis_cluster_endpoint) \
./03-deploy-livekit.sh
```

## 🗑️ Destroy Infrastructure

To destroy everything:

```bash
cd resources
terraform destroy -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
```

Or use the GitHub Actions pipeline with `action: destroy`.

## ⚙️ Configuration

### Key Settings

- **Kubernetes Version**: 1.34 (latest, no extended support charges)
- **Node Type**: t3.medium
- **Node Count**: 2-5 (desired: 3)
- **AMI**: AL2023_x86_64_STANDARD
- **Redis**: cache.t3.micro

### Environment Variables

Set these in your GitHub repository secrets:

- `AWS_OIDC_ROLE_ARN`: OIDC role for GitHub Actions
- `DEPLOYMENT_ROLE_ARN`: Role for Terraform deployment

### Customization

Edit `environments/livekit-poc/us-east-1/dev/inputs.tfvars` to customize:

- VPC CIDR blocks
- Instance types
- Redis node type
- Twilio CIDR blocks
- Cluster version

## 🔐 Security

- **SIP Traffic**: Port 5060 restricted to Twilio CIDRs only
- **Redis**: Encrypted at rest, VPC-only access
- **EKS**: Private subnets, managed node groups
- **IAM**: Least privilege access with EKS Access Entries

## 📊 Monitoring

The infrastructure includes:

- EKS cluster logging
- CloudWatch metrics
- VPC Flow Logs (optional)
- Redis monitoring

## 🆘 Troubleshooting

### Common Issues

1. **S3 Backend Access**: Ensure your AWS credentials can access the S3 bucket
2. **EKS Permissions**: Verify the deployment role has EKS permissions
3. **VPC Limits**: Check AWS VPC limits in your region
4. **Redis Subnet Groups**: Ensure private subnets are in different AZs

### Useful Commands

```bash
# Check cluster status
kubectl get nodes

# Check LiveKit pods
kubectl get pods -n livekit

# Check Load Balancer Controller
kubectl get deployment -n kube-system aws-load-balancer-controller

# Get LoadBalancer endpoint
kubectl get svc -n livekit
```

## 📝 Version Information

- **Terraform**: 1.10.3
- **EKS Module**: ~> 21.0
- **VPC Module**: ~> 5.0
- **ElastiCache Module**: ~> 1.0
- **Kubernetes**: 1.34
- **kubectl**: 1.30.0
- **Helm**: 3.16.3
- **eksctl**: 0.191.0

## 🤝 Contributing

1. Make changes to the appropriate files
2. Test locally with `terraform plan`
3. Submit a pull request
4. Pipeline will validate changes

## 📄 License

This project is licensed under the MIT License.