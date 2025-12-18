# LiveKit EKS Deployment Workflow Guide

This guide explains how to use the GitHub Actions workflow to deploy LiveKit on Amazon EKS with manual approval gates.

## 🎯 Overview

The deployment pipeline consists of 6 main steps, each requiring manual approval:

1. **Prerequisites Check** - Verify and install required tools
2. **Terraform Plan** - Create infrastructure execution plan
3. **Infrastructure Deployment** - Deploy EKS, VPC, Redis, and Security Groups
4. **Load Balancer Setup** - Install AWS Load Balancer Controller
5. **LiveKit Deployment** - Deploy LiveKit with Redis integration
6. **Destroy Infrastructure** - Optional cleanup step

## 🔧 Prerequisites

### 1. OIDC Setup
Follow the [OIDC Setup Guide](../.github/OIDC_SETUP.md) to configure secure authentication between GitHub Actions and AWS.

### 2. GitHub Environment Setup
Create the following environments in your repository (Settings → Environments):

- `dev-prerequisites`
- `dev-terraform-plan`
- `dev-terraform-apply`
- `dev-load-balancer`
- `dev-livekit`
- `dev-destroy`

For each environment, configure:
- **Required reviewers**: Add team members who can approve deployments
- **Wait timer**: Optional delay before deployment (recommended: 5 minutes for production)

### 3. Repository Secrets
Ensure the following secret is configured:
- `AWS_OIDC_ROLE_ARN`: ARN of the IAM role for GitHub Actions

## 🚀 Running the Workflow

### Step-by-Step Deployment

1. **Navigate to Actions Tab**
   - Go to your repository → Actions
   - Select "LiveKit EKS Manual Deployment Pipeline"

2. **Choose Deployment Options**
   - **Environment**: `dev`, `uat`, or `prod`
   - **Step**: Choose specific step or `all` for complete deployment

3. **Manual Approval Process**
   Each step requires manual approval:
   - Review the deployment details in the approval screen
   - Check resource costs and impact
   - Approve or reject the deployment

### Deployment Scenarios

#### Complete Deployment (Recommended for first-time setup)
```
Environment: dev
Step: all
```
This runs all steps sequentially with approval gates.

#### Individual Step Deployment
```
Environment: dev
Step: terraform-plan
```
Run specific steps for troubleshooting or partial deployments.

#### Infrastructure Cleanup
```
Environment: dev
Step: destroy
```
⚠️ **WARNING**: This permanently deletes all resources and data!

## 📊 What Gets Deployed

### Infrastructure Resources
- **EKS Cluster**: `lp-eks-livekit-use1-dev`
- **VPC**: `lp-vpc-main-use1-dev` with public/private subnets
- **ElastiCache Redis**: `lp-ec-redis-use1-dev`
- **Security Groups**: SIP traffic (port 5060) restricted to Twilio CIDRs
- **NAT Gateways**: 3x for high availability

### Kubernetes Resources
- **Namespace**: `livekit`
- **AWS Load Balancer Controller**: For ALB ingress
- **LiveKit Server**: With Redis integration
- **ALB Ingress**: SSL termination with ACM certificate

### Estimated Monthly Costs
- **EKS Cluster**: ~$72/month
- **NAT Gateways**: ~$135/month (3x $45 each)
- **ElastiCache Redis**: ~$15/month
- **EC2 Instances**: ~$60/month (2x t3.medium)
- **Total**: ~$282/month

## 🔍 Monitoring Deployment

### GitHub Actions Interface
- **Real-time logs**: View step execution in Actions tab
- **Approval notifications**: Get notified when approval is needed
- **Deployment summary**: Comprehensive report at the end

### AWS Console Verification
```bash
# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev

# Check cluster status
kubectl get nodes
kubectl get pods -n livekit

# Verify LiveKit deployment
kubectl get ingress -n livekit
kubectl logs -n livekit -l app.kubernetes.io/name=livekit
```

## 🛠️ Troubleshooting

### Common Issues

#### 1. OIDC Authentication Failures
```
Error: AssumeRoleWithWebIdentity is not authorized
```
**Solution**: Verify OIDC setup and trust policy conditions

#### 2. Terraform Plan Failures
```
Error: creating EKS Node Group: InvalidParameterException
```
**Solution**: Check node group configuration and security groups

#### 3. Load Balancer Controller Issues
```
Error: failed to install aws-load-balancer-controller
```
**Solution**: Verify IAM OIDC provider and service account permissions

#### 4. LiveKit Deployment Failures
```
Error: Redis connection failed
```
**Solution**: Check Redis endpoint and security group rules

### Debug Commands

```bash
# Check EKS cluster status
aws eks describe-cluster --name lp-eks-livekit-use1-dev --region us-east-1

# Verify Redis connectivity
aws elasticache describe-replication-groups --region us-east-1

# Check security groups
aws ec2 describe-security-groups --region us-east-1 --filters "Name=group-name,Values=*sip*"

# Kubernetes debugging
kubectl describe pods -n livekit
kubectl get events -n livekit --sort-by='.lastTimestamp'
```

## 🔄 Workflow Customization

### Environment Variables
The workflow uses these environment variables:
- `AWS_REGION`: Target AWS region (default: us-east-1)
- `TERRAFORM_VERSION`: Terraform version (default: 1.6.0)
- `KUBECTL_VERSION`: kubectl version (default: v1.28.0)
- `HELM_VERSION`: Helm version (default: v3.13.0)

### Script Customization
Scripts are located in `scripts/` directory:
- `00-prerequisites.sh`: Tool installation and verification
- `01-deploy-infrastructure.sh`: Terraform deployment
- `02-setup-load-balancer.sh`: Load balancer controller setup
- `03-deploy-livekit.sh`: LiveKit deployment
- `cleanup.sh`: Infrastructure cleanup

## 🔐 Security Considerations

### Network Security
- **Private subnets**: EKS nodes run in private subnets
- **SIP restrictions**: Port 5060 limited to Twilio CIDRs only
- **ALB ingress**: SSL termination with ACM certificates

### Access Control
- **OIDC authentication**: No long-lived AWS credentials
- **Manual approvals**: Human verification for each step
- **Environment protection**: Branch and reviewer restrictions

### Monitoring
- **CloudTrail**: All AWS API calls logged
- **EKS logging**: Control plane logs enabled
- **Prometheus**: Metrics collection enabled

## 📋 Post-Deployment Checklist

### Verification Steps
- [ ] EKS cluster is healthy and accessible
- [ ] LiveKit pods are running and ready
- [ ] ALB ingress has valid SSL certificate
- [ ] Redis connectivity is working
- [ ] SIP traffic is properly restricted
- [ ] Monitoring and logging are functional

### Testing
- [ ] Test WebRTC connection to LiveKit
- [ ] Verify SIP connectivity from Twilio
- [ ] Check TURN server functionality
- [ ] Validate SSL certificate
- [ ] Test autoscaling behavior

### Documentation
- [ ] Update DNS records if needed
- [ ] Document access credentials
- [ ] Create monitoring dashboards
- [ ] Set up alerting rules

## 🆘 Support

### Getting Help
1. **Check workflow logs**: Detailed error messages in Actions tab
2. **Review script output**: Each script provides verbose logging
3. **AWS Console**: Verify resource creation and status
4. **Kubernetes logs**: Check pod and service status

### Rollback Procedures
1. **Partial rollback**: Run individual steps to fix issues
2. **Complete rollback**: Use destroy step to clean up
3. **Manual cleanup**: Use AWS Console for stuck resources

### Contact Information
- **DevOps Team**: For infrastructure issues
- **Platform Team**: For LiveKit configuration
- **Security Team**: For access and compliance issues