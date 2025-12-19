# IAM Permissions Setup for EKS Access

This guide explains how to set up the necessary IAM permissions for the deployment role to access and manage the EKS cluster.

## Problem

The deployment role needs comprehensive permissions to:
- Access EKS cluster API
- Manage EKS resources
- Create and manage IAM service accounts
- Work with Auto Scaling groups
- Manage Load Balancers

## Solution

### Option 1: Use the Comprehensive Policy (Recommended)

The Terraform configuration now includes a comprehensive IAM policy that provides all necessary permissions.

#### Step 1: Apply the IAM Policy
```bash
# Navigate to resources directory
cd livekit-poc-infra/resources

# Plan and apply to create the policy
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# Note the policy ARN from the output
```

#### Step 2: Attach Policy to Deployment Role
```bash
# Get the policy ARN from Terraform output
POLICY_ARN=$(terraform output -raw eks_comprehensive_policy_arn)

# Attach to your deployment role
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn "$POLICY_ARN"
```

### Option 2: Use AWS Managed Policies (Quick Fix)

If you need immediate access, attach these AWS managed policies to your deployment role:

```bash
# Core EKS permissions
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# Worker node permissions
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

# CNI permissions
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

# Container registry permissions
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSContainerRegistryPolicy

# Full EC2 access (for node management)
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

# IAM permissions for service accounts
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

# Auto Scaling permissions
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess

# Load Balancer permissions
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess

# CloudFormation permissions (for eksctl)
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/CloudFormationFullAccess
```

### Option 3: Admin Access (Temporary)

For immediate testing, you can temporarily grant admin access:

```bash
# WARNING: This gives full AWS access - use only for testing
aws iam attach-role-policy \
  --role-name lp-iam-resource-creation-role \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

## Verification

After attaching the policies, verify the role has the necessary permissions:

```bash
# List attached policies
aws iam list-attached-role-policies --role-name lp-iam-resource-creation-role

# Test EKS access
aws eks describe-cluster --name lp-eks-livekit-use1-dev --region us-east-1

# Test kubectl access (after updating kubeconfig)
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev
kubectl get nodes
```

## Required Permissions Breakdown

### Core EKS Permissions
- `eks:*` - Full EKS access
- `sts:AssumeRole` - Assume service roles
- `sts:GetCallerIdentity` - Identity verification

### Node Management
- `ec2:Describe*` - View EC2 resources
- `autoscaling:*` - Manage Auto Scaling groups
- `ec2:CreateTags`, `ec2:DeleteTags` - Tag management

### Service Account Management
- `iam:CreateRole`, `iam:DeleteRole` - Manage IAM roles
- `iam:AttachRolePolicy`, `iam:DetachRolePolicy` - Policy management
- `iam:PassRole` - Pass roles to services

### Load Balancer Controller
- `elasticloadbalancing:*` - Manage load balancers
- `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups` - Network info

### Logging and Monitoring
- `logs:*` - CloudWatch Logs access
- `cloudwatch:*` - CloudWatch metrics

## Troubleshooting

### Common Permission Errors

1. **"AccessDenied" when running kubectl**
   - Solution: Ensure role has `eks:AccessKubernetesApi` permission

2. **"Forbidden" when creating service accounts**
   - Solution: Add IAM permissions for role and policy management

3. **Load balancer controller fails to install**
   - Solution: Add ELB and EC2 describe permissions

4. **eksctl commands fail**
   - Solution: Add CloudFormation permissions

### Testing Individual Permissions

```bash
# Test EKS access
aws eks list-clusters --region us-east-1

# Test IAM access
aws iam list-roles --max-items 1

# Test EC2 access
aws ec2 describe-instances --region us-east-1 --max-items 1

# Test Auto Scaling access
aws autoscaling describe-auto-scaling-groups --region us-east-1 --max-items 1
```

## Security Best Practices

1. **Use Least Privilege**: Start with the comprehensive policy, then remove unused permissions
2. **Regular Audits**: Review attached policies periodically
3. **Temporary Admin**: Remove admin access after testing
4. **Resource-Specific**: Consider restricting to specific EKS clusters in production

## Next Steps

1. Apply the IAM policy using Terraform
2. Attach the policy to your deployment role
3. Re-run the failed pipeline step
4. Monitor CloudTrail for any remaining permission issues
5. Refine permissions based on actual usage patterns