# Manual Deployment Guide

This guide provides step-by-step instructions for manually deploying LiveKit on EKS using the provided scripts.

## 🚀 Quick Start

### Prerequisites Check and Installation
```bash
# Make scripts executable
chmod +x scripts/*.sh

# Check and install prerequisites (with auto-installation)
./scripts/00-prerequisites.sh
```

### Complete Deployment
```bash
# Option 1: Deploy everything at once
./scripts/deploy-all.sh

# Option 2: Step-by-step deployment
./scripts/01-deploy-infrastructure.sh
./scripts/02-setup-load-balancer.sh  
./scripts/03-deploy-livekit.sh
```

## 📋 Detailed Step-by-Step Process

### Step 1: Prerequisites Setup

The prerequisites script will automatically detect your OS and install missing tools:

```bash
./scripts/00-prerequisites.sh
```

**What it installs:**
- AWS CLI v2
- Terraform (latest)
- kubectl
- Helm 3
- eksctl
- jq

**Manual installation (if script fails):**

**Linux (Ubuntu/Debian):**
```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Terraform
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm
curl https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz | tar -xz
sudo mv linux-amd64/helm /usr/local/bin/

# eksctl
curl -sLO "https://github.com/eksctl-io/eksctl/releases/download/0.165.0/eksctl_Linux_amd64.tar.gz"
tar -xzf eksctl_Linux_amd64.tar.gz
sudo mv eksctl /usr/local/bin/

# jq
sudo apt-get update && sudo apt-get install -y jq
```

**macOS:**
```bash
# Install Homebrew first if not installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install tools
brew install awscli terraform kubectl helm eksctl jq
```

### Step 2: AWS Configuration

```bash
# Configure AWS credentials
aws configure

# Verify configuration
aws sts get-caller-identity
```

### Step 3: Infrastructure Deployment

```bash
# Deploy EKS cluster, VPC, and Redis
./scripts/01-deploy-infrastructure.sh
```

**What this creates:**
- VPC with public/private subnets across 3 AZs
- EKS cluster with managed node groups
- ElastiCache Redis cluster
- Security groups (SIP port 5060 restricted to Twilio CIDRs)
- IAM roles and policies

**Manual approval required:** The script will ask for confirmation before applying changes.

**Troubleshooting:**
```bash
# If deployment fails, check Terraform state
cd livekit-poc-infra/resources
terraform show

# Check for resource conflicts
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# Force unlock if state is locked
terraform force-unlock <LOCK_ID>
```

### Step 4: Load Balancer Controller Setup

```bash
# Install AWS Load Balancer Controller
./scripts/02-setup-load-balancer.sh
```

**What this installs:**
- IAM OIDC identity provider for the cluster
- IAM service account for AWS Load Balancer Controller
- AWS Load Balancer Controller via Helm

**Manual verification:**
```bash
# Check if controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller

# Check controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller
```

### Step 5: LiveKit Deployment

```bash
# Deploy LiveKit with proper configuration
./scripts/03-deploy-livekit.sh
```

**What this deploys:**
- LiveKit namespace
- LiveKit server with Redis integration
- ALB ingress with SSL certificate
- TURN server configuration

**Manual verification:**
```bash
# Switch to livekit namespace
kubectl config set-context --current --namespace=livekit

# Check pod status
kubectl get pods -w

# Check services
kubectl get services

# Check ingress
kubectl get ingress

# View logs
kubectl logs -l app.kubernetes.io/name=livekit -f
```

## 🔧 Configuration Customization

### Environment Variables

You can customize the deployment by setting environment variables:

```bash
# Set environment (dev/uat/prod)
export ENVIRONMENT=dev

# Set AWS region
export AWS_REGION=us-east-1

# Auto-approve Terraform (for CI/CD)
export TF_AUTO_APPROVE=true

# Skip prerequisites check
export SKIP_PREREQUISITES=true
```

### Custom Values for LiveKit

Edit `DeploymentFile/livekit-values.yaml` to customize:

```yaml
livekit:
  domain: your-domain.com
  resources:
    requests:
      cpu: 1000m
      memory: 1Gi
    limits:
      cpu: 4000m
      memory: 4Gi

loadBalancer:
  tls:
    - hosts:
        - your-domain.com
      certificateArn: arn:aws:acm:region:account:certificate/cert-id
```

### Terraform Variables

Modify `livekit-poc-infra/environments/livekit-poc/us-east-1/dev/inputs.tfvars`:

```hcl
# EKS Configuration
cluster_version = "1.28"
node_groups = {
  livekit_nodes = {
    instance_types = ["t3.large"]
    min_size       = 2
    max_size       = 20
    desired_size   = 4
  }
}

# Redis Configuration
redis_node_type = "cache.t3.small"

# Security - Add your IP for additional access
additional_cidrs = ["YOUR_IP/32"]
```

## 🔍 Monitoring and Troubleshooting

### Health Checks

```bash
# Check cluster health
kubectl get nodes
kubectl get pods --all-namespaces

# Check LiveKit health
kubectl get pods -n livekit
kubectl describe pod -n livekit <pod-name>

# Check ingress
kubectl describe ingress -n livekit

# Test Redis connectivity
kubectl run redis-test --image=redis:alpine --rm -it -- redis-cli -h <redis-endpoint> ping
```

### Common Issues and Solutions

**1. EKS Node Group Creation Fails**
```bash
# Check IAM permissions
aws iam get-role --role-name <node-group-role>

# Check subnet tags
aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/cluster/*,Values=shared"
```

**2. Load Balancer Controller Not Working**
```bash
# Check OIDC provider
aws iam list-open-id-connect-providers

# Check service account
kubectl describe serviceaccount aws-load-balancer-controller -n kube-system

# Reinstall controller
helm uninstall aws-load-balancer-controller -n kube-system
./scripts/02-setup-load-balancer.sh
```

**3. LiveKit Pods Not Starting**
```bash
# Check Redis connectivity
kubectl exec -it <livekit-pod> -n livekit -- redis-cli -h <redis-endpoint> ping

# Check resource limits
kubectl describe pod <livekit-pod> -n livekit

# Check logs
kubectl logs <livekit-pod> -n livekit
```

**4. Ingress Not Creating ALB**
```bash
# Check ingress annotations
kubectl describe ingress -n livekit

# Check ALB controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# Verify subnet tags
aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/role/elb,Values=1"
```

### Useful Commands

```bash
# Get all Terraform outputs
cd livekit-poc-infra/resources
terraform output

# Port forward for local testing
kubectl port-forward svc/livekit 7880:80 -n livekit

# Scale LiveKit deployment
kubectl scale deployment livekit -n livekit --replicas=3

# Update LiveKit configuration
helm upgrade livekit livekit/livekit -f DeploymentFile/livekit-values.yaml -n livekit

# Check resource usage
kubectl top nodes
kubectl top pods -n livekit
```

## 🧹 Cleanup

### Partial Cleanup
```bash
# Remove only LiveKit
helm uninstall livekit -n livekit
kubectl delete namespace livekit

# Remove Load Balancer Controller
helm uninstall aws-load-balancer-controller -n kube-system
```

### Complete Cleanup
```bash
# Destroy all infrastructure
./scripts/cleanup.sh

# Or manually
cd livekit-poc-infra/resources
terraform destroy -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
```

## 📞 Support

If you encounter issues:

1. Check the logs in each step
2. Verify AWS permissions
3. Ensure all prerequisites are installed
4. Check the troubleshooting section above
5. Review AWS CloudTrail for permission issues

For additional help, check:
- [EKS Troubleshooting Guide](https://docs.aws.amazon.com/eks/latest/userguide/troubleshooting.html)
- [LiveKit Documentation](https://docs.livekit.io/)
- [AWS Load Balancer Controller Troubleshooting](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/troubleshooting/)