# Quick Reference Guide

## GitHub Actions Deployment (Recommended)

### 🚀 Complete Deployment
1. Go to **Actions** → **LiveKit EKS Manual Deployment Pipeline**
2. Click **Run workflow**
3. Select `environment: dev` and `step: all`
4. Approve each step when prompted

### 🗑️ Destroy Infrastructure
1. Run workflow with `step: destroy`
2. Approve the destruction (⚠️ **ALL DATA WILL BE LOST!**)

## Manual Commands

### Terraform Operations
```bash
cd resources

# Initialize
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"

# Plan
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# Apply
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# Destroy
terraform destroy -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
```

### Kubernetes Operations
```bash
# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev

# Check LiveKit status
kubectl get pods -n livekit
kubectl get svc -n livekit
kubectl get ingress -n livekit

# View logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit -f

# Check cluster health
kubectl get nodes
kubectl get pods -n kube-system
```

## Access Information

- **LiveKit URL**: https://livekit-eks.digi-telephony.com
- **TURN Server**: turn-eks.livekit.digi-telephony.com:3478
- **Cluster Name**: lp-eks-livekit-use1-dev
- **Redis**: Use `terraform output redis_cluster_endpoint`

## Troubleshooting

### Common Issues
```bash
# EKS addon status
aws eks describe-addon --cluster-name lp-eks-livekit-use1-dev --addon-name aws-ebs-csi-driver --region us-east-1

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp -n livekit

# Load balancer controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### GitHub Secrets Required
- `AWS_OIDC_ROLE_ARN`: GitHub OIDC role ARN
- `DEPLOYMENT_ROLE_ARN`: AWS deployment role ARN

See [OIDC_SETUP.md](OIDC_SETUP.md) and [ROLE_SETUP.md](ROLE_SETUP.md) for setup instructions.

## Cost Information

**Estimated Monthly Cost**: ~$317
- EKS Cluster: $72
- NAT Gateways (3x): $135  
- ElastiCache Redis: $15
- EC2 Instances (3x t3.medium): $95