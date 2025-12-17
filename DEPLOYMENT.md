# LiveKit EKS Deployment Guide

This guide provides step-by-step instructions to deploy LiveKit on Amazon EKS with proper security configurations.

## 🏗️ Architecture Overview

- **EKS Cluster**: `lp-eks-livekit-use1-dev`
- **VPC**: `lp-vpc-main-use1-dev` with public/private subnets
- **ElastiCache Redis**: `lp-ec-redis-use1-dev` for session storage
- **Security**: Port 5060 (SIP) restricted to Twilio CIDRs only
- **Load Balancer**: AWS ALB with SSL termination
- **Naming Convention**: `<company>-<service>-<name>-<region>-<env>`

## 📋 Prerequisites

Run the prerequisites check:
```bash
./scripts/00-prerequisites.sh
```

Required tools:
- AWS CLI (configured with credentials)
- kubectl
- Helm 3.x
- eksctl
- Terraform
- jq

## 🚀 Quick Deployment

### Option 1: Complete Automated Deployment
```bash
# Deploy everything in one go
./scripts/deploy-all.sh
```

### Option 2: Step-by-Step Deployment

#### Step 1: Deploy Infrastructure
```bash
./scripts/01-deploy-infrastructure.sh
```
This creates:
- VPC with public/private subnets
- EKS cluster with node groups
- ElastiCache Redis cluster
- Security groups (SIP port 5060 restricted to Twilio)

#### Step 2: Install AWS Load Balancer Controller
```bash
./scripts/02-setup-load-balancer.sh
```
This installs:
- IAM OIDC provider
- IAM roles and policies
- AWS Load Balancer Controller via Helm

#### Step 3: Deploy LiveKit
```bash
./scripts/03-deploy-livekit.sh
```
This deploys:
- LiveKit namespace
- LiveKit server with Redis integration
- ALB ingress with SSL certificate

## 🔧 Configuration Details

### Security Groups
- **SIP Traffic**: Port 5060 (TCP/UDP) restricted to Twilio CIDRs only
- **HTTPS**: Port 443 for web traffic
- **WebRTC**: Ports 50000-60000 for media traffic

### Redis Configuration
- **Endpoint**: Automatically configured from Terraform output
- **Port**: 6379
- **Encryption**: At-rest encryption enabled
- **Network**: Private subnets only

### SSL Certificate
- **Domain**: `livekit-eks.digi-telephony.com`
- **Certificate ARN**: `arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414`
- **TURN Domain**: `turn-eks.livekit.digi-telephony.com`

## 📊 Monitoring & Verification

### Check Infrastructure
```bash
# Verify EKS cluster
kubectl get nodes

# Check Redis connectivity
kubectl run redis-test --image=redis:alpine --rm -it -- redis-cli -h <redis-endpoint> ping

# Verify security groups
aws ec2 describe-security-groups --group-names "*sip*"
```

### Check LiveKit Deployment
```bash
# Switch to livekit namespace
kubectl config set-context --current --namespace=livekit

# Check pods
kubectl get pods -l app.kubernetes.io/name=livekit

# Check services
kubectl get services

# Check ingress
kubectl get ingress

# View logs
kubectl logs -l app.kubernetes.io/name=livekit -f
```

### Check Load Balancer
```bash
# Verify ALB controller
kubectl get deployment -n kube-system aws-load-balancer-controller

# Check ALB creation
kubectl describe ingress -n livekit
```

## 🌐 Access Points

- **LiveKit Server**: https://livekit-eks.digi-telephony.com
- **TURN Server**: turn-eks.livekit.digi-telephony.com:3478
- **Metrics**: Available via Prometheus on port 6789

## 🔑 API Keys

The LiveKit server is configured with:
- **API Key**: `APIKmrHi78hxpbd`
- **Secret**: `Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB`

## 🧹 Cleanup

To destroy all resources:
```bash
./scripts/cleanup.sh
```

⚠️ **Warning**: This will permanently delete all resources including data in Redis.

## 🔍 Troubleshooting

### Common Issues

1. **EKS Node Group Labels Error**
   - Fixed: Removed reserved `k8s.io/` prefixes from labels

2. **Security Group Missing**
   - Fixed: Added dedicated security group for SIP traffic (port 5060)

3. **Redis Connection Issues**
   - Check: Redis endpoint in values.yaml matches Terraform output
   - Verify: Security groups allow EKS nodes to access Redis

4. **Load Balancer Not Creating**
   - Check: AWS Load Balancer Controller is installed
   - Verify: IAM roles and policies are correct
   - Check: Subnets have proper tags for ALB

### Useful Commands

```bash
# Get cluster info
terraform output -raw cluster_name
terraform output -raw redis_cluster_endpoint

# Debug pods
kubectl describe pod <pod-name> -n livekit

# Check events
kubectl get events -n livekit --sort-by='.lastTimestamp'

# Port forward for testing
kubectl port-forward svc/livekit 7880:80 -n livekit
```

## 📝 Resource Naming

All resources follow the naming convention:
`<company-prefix>-<service>-<custom-name>-<region-prefix>-<env>`

Examples:
- VPC: `lp-vpc-main-use1-dev`
- EKS: `lp-eks-livekit-use1-dev`
- Redis: `lp-ec-redis-use1-dev`
- Security Group: `lp-sg-sip-twilio-use1-dev`

## 🎯 Next Steps

After successful deployment:
1. Test SIP connectivity from Twilio
2. Verify WebRTC media flow
3. Set up monitoring and alerting
4. Configure backup strategies for Redis
5. Implement CI/CD pipelines for updates