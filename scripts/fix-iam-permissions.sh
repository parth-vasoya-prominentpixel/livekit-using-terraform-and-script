#!/bin/bash

# Script to attach necessary IAM policies to the deployment role for EKS access
# This provides comprehensive permissions needed for EKS cluster management

set -e

ROLE_NAME="lp-iam-resource-creation-role"
AWS_REGION="us-east-1"

echo "🔧 Fixing IAM permissions for EKS access..."
echo "📋 Role: $ROLE_NAME"
echo "📋 Region: $AWS_REGION"

# Check if role exists
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "❌ Role $ROLE_NAME does not exist"
    exit 1
fi

echo "✅ Role $ROLE_NAME exists"

# Function to attach policy with error handling
attach_policy() {
    local policy_arn=$1
    local policy_name=$2
    
    echo "🔗 Attaching $policy_name..."
    if aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null; then
        echo "✅ Attached $policy_name"
    else
        echo "⚠️ $policy_name already attached or failed to attach"
    fi
}

# Attach AWS managed policies for comprehensive EKS access
echo "📋 Attaching AWS managed policies..."

# Core EKS permissions
attach_policy "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" "EKS Cluster Policy"

# Worker node permissions  
attach_policy "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" "EKS Worker Node Policy"

# CNI permissions
attach_policy "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" "EKS CNI Policy"

# Container registry permissions
attach_policy "arn:aws:iam::aws:policy/AmazonEKSContainerRegistryPolicy" "EKS Container Registry Policy"

# EC2 permissions for node management
attach_policy "arn:aws:iam::aws:policy/AmazonEC2FullAccess" "EC2 Full Access"

# IAM permissions for service accounts
attach_policy "arn:aws:iam::aws:policy/IAMFullAccess" "IAM Full Access"

# Auto Scaling permissions
attach_policy "arn:aws:iam::aws:policy/AutoScalingFullAccess" "Auto Scaling Full Access"

# Load Balancer permissions
attach_policy "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess" "ELB Full Access"

# CloudFormation permissions (for eksctl)
attach_policy "arn:aws:iam::aws:policy/CloudFormationFullAccess" "CloudFormation Full Access"

# CloudWatch permissions
attach_policy "arn:aws:iam::aws:policy/CloudWatchFullAccess" "CloudWatch Full Access"

# Application Auto Scaling
attach_policy "arn:aws:iam::aws:policy/application-autoscaling:*" "Application Auto Scaling" || echo "⚠️ Application Auto Scaling policy not found, skipping"

echo ""
echo "✅ IAM permissions setup completed!"
echo ""
echo "📋 Attached policies:"
aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyName' --output table

echo ""
echo "🔍 Testing EKS access..."
if aws eks describe-cluster --name "lp-eks-livekit-use1-dev" --region "$AWS_REGION" --query 'cluster.{Name:name,Status:status}' --output table 2>/dev/null; then
    echo "✅ EKS access test successful!"
else
    echo "⚠️ EKS access test failed - may need to wait a few minutes for permissions to propagate"
fi

echo ""
echo "💡 Next steps:"
echo "1. Wait 2-3 minutes for IAM permissions to propagate"
echo "2. Re-run the failed pipeline step"
echo "3. If still failing, check the troubleshooting guide in docs/IAM_PERMISSIONS_SETUP.md"
echo ""
echo "🚀 Ready to retry the deployment!"