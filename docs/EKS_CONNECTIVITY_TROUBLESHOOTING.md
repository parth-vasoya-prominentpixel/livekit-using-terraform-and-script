# EKS Connectivity Troubleshooting Guide

This guide helps resolve common EKS cluster connectivity issues, especially when accessing the cluster from GitHub Actions or local environments.

## Common Issues and Solutions

### 1. "Cluster not accessible" Error

**Symptoms:**
- `kubectl get nodes` times out or fails
- "connection refused" or "timeout" errors
- Pipeline fails at load balancer setup step

**Causes & Solutions:**

#### A. Cluster Still Being Created
- **Check**: Cluster status in AWS Console or CLI
- **Solution**: Wait for cluster to be in "ACTIVE" state (15-20 minutes)
- **Command**: `aws eks describe-cluster --name CLUSTER_NAME --region REGION --query 'cluster.status'`

#### B. Endpoint Access Configuration
- **Check**: Cluster endpoint access settings
- **Current Config**: Public endpoint enabled with 0.0.0.0/0 access
- **Verify**: `aws eks describe-cluster --name CLUSTER_NAME --query 'cluster.resourcesVpcConfig'`

#### C. IAM Permissions
- **Check**: GitHub Actions role has EKS permissions
- **Required Permissions**:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ],
        "Resource": "*"
      }
    ]
  }
  ```

#### D. Kubeconfig Issues
- **Check**: Kubeconfig is properly updated
- **Solution**: Re-run `aws eks update-kubeconfig`
- **Command**: `aws eks update-kubeconfig --region REGION --name CLUSTER_NAME`

### 2. Authentication/Authorization Errors

**Symptoms:**
- "Unauthorized" or "Forbidden" errors
- "You must be logged in to the server" messages

**Solutions:**

#### A. Access Entries Configuration
The cluster is configured with access entries for the deployment role:
```hcl
access_entries = {
  deployment_role = {
    kubernetes_groups = ["system:masters"]
    principal_arn     = var.deployment_role_arn
    type             = "STANDARD"
  }
}
```

#### B. Verify Role Assumption
- **Check**: GitHub Actions is assuming the correct role
- **Verify**: `aws sts get-caller-identity` shows the deployment role

### 3. Network Connectivity Issues

**Symptoms:**
- Connection timeouts
- DNS resolution failures

**Solutions:**

#### A. Security Groups
- **Check**: EKS cluster security group allows HTTPS (443) inbound
- **Default**: EKS module creates appropriate security groups automatically

#### B. VPC Configuration
- **Check**: VPC has internet gateway and proper routing
- **Current**: Public subnets with IGW, private subnets with NAT Gateway

### 4. GitHub Actions Specific Issues

**Common Problems:**

#### A. Runner IP Changes
- **Issue**: GitHub Actions runners have dynamic IPs
- **Solution**: Use 0.0.0.0/0 for public endpoint access (already configured)

#### B. Timeout Issues
- **Issue**: Default timeouts too short for cluster operations
- **Solution**: Extended timeouts in scripts (45 seconds per attempt, 15 attempts)

#### C. Race Conditions
- **Issue**: Trying to access cluster before it's fully ready
- **Solution**: Added 2-minute wait + status verification before load balancer setup

## Debugging Commands

### Check Cluster Status
```bash
aws eks describe-cluster --name CLUSTER_NAME --region REGION --query 'cluster.{Status:status,Endpoint:endpoint,Version:version}' --output table
```

### Test Endpoint Connectivity
```bash
ENDPOINT=$(aws eks describe-cluster --name CLUSTER_NAME --region REGION --query 'cluster.endpoint' --output text)
curl -k -s --connect-timeout 10 "$ENDPOINT/healthz"
```

### Verify Kubeconfig
```bash
kubectl config current-context
kubectl config get-contexts
kubectl cluster-info
```

### Check IAM Identity
```bash
aws sts get-caller-identity
```

### Test Basic Kubectl Access
```bash
kubectl auth can-i get nodes
kubectl get nodes
kubectl get pods -A
```

## Pipeline Improvements Made

### 1. Extended Wait Times
- Increased initial wait from 60 to 120 seconds
- Added cluster status verification before proceeding

### 2. Better Error Handling
- 3 attempts with 30-second intervals (fast failure detection)
- Detailed debugging information on each attempt
- Comprehensive endpoint and network connectivity testing
- JSON parsing with jq for detailed cluster information

### 3. Enhanced Logging
- Show cluster endpoint and status
- Display current kubectl context
- Provide troubleshooting hints on failure

### 4. Access Configuration
- Added deployment role to cluster access entries
- Enabled both API and ConfigMap authentication modes
- Bootstrap self-managed addons for better compatibility

## Manual Troubleshooting Steps

If the pipeline fails, you can troubleshoot manually:

### 1. From AWS CloudShell
```bash
# CloudShell has AWS CLI pre-configured
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev
kubectl get nodes
```

### 2. From Local Machine
```bash
# Ensure AWS CLI is configured with correct credentials
aws configure list
aws sts get-caller-identity

# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev

# Test connectivity
kubectl get nodes
```

### 3. Check Cluster in AWS Console
1. Go to EKS service in AWS Console
2. Select your cluster
3. Check "Overview" tab for status
4. Check "Networking" tab for endpoint configuration
5. Check "Access" tab for authentication settings

## Prevention Tips

1. **Always wait for cluster to be ACTIVE** before attempting connections
2. **Use consistent IAM roles** between Terraform and kubectl operations
3. **Monitor cluster creation logs** in CloudTrail for issues
4. **Test connectivity** before proceeding with application deployments
5. **Use CloudShell** as a backup access method when local access fails

## Contact Support

If issues persist:
1. Check AWS CloudTrail logs for EKS API calls
2. Review VPC Flow Logs for network connectivity
3. Verify IAM policies and trust relationships
4. Consider using AWS Support for complex networking issues