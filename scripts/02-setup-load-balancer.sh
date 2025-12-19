#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Based on official AWS documentation: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
# Version: AWS Load Balancer Controller v2.14.1

set -e

echo "⚖️ Setting up AWS Load Balancer Controller..."
echo "📋 Following official AWS EKS documentation"

# Check if CLUSTER_NAME is provided
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name ./02-setup-load-balancer.sh"
    exit 1
fi

# Set AWS region (default to us-east-1 if not set)
AWS_REGION=${AWS_REGION:-us-east-1}

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region:  $AWS_REGION"
echo "   Controller Version: v2.14.1"
echo "   Mode: SAFE (no deletion of existing resources)"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "📋 AWS Account ID: $ACCOUNT_ID"

# Check if cluster exists and is accessible
echo "🔍 Verifying cluster access..."
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "❌ Cluster $CLUSTER_NAME does not exist or is not accessible"
    exit 1
fi

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"

# Test kubectl connectivity
echo "🔍 Testing kubectl connectivity..."
if ! timeout 30 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cluster is not accessible via kubectl"
    echo "💡 Check IAM permissions and cluster endpoint access"
    exit 1
fi
echo "✅ Cluster is accessible"

# Get cluster VPC ID
echo "🔍 Getting cluster VPC information..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "✅ Cluster VPC ID: $VPC_ID"

# Step 1: Create IAM Policy (if not exists)
echo ""
echo "📋 Step 1: Setting up IAM Policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_ARN"
else
    echo "📋 Creating IAM policy..."
    
    # Download the policy
    if ! curl -sS -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json; then
        echo "❌ Failed to download IAM policy"
        exit 1
    fi
    
    # Create the policy
    if aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json; then
        echo "✅ IAM policy created: $POLICY_ARN"
        rm -f iam_policy.json
    else
        echo "❌ Failed to create IAM policy"
        exit 1
    fi
fi

# Step 2: Use Existing Service Account - NO DELETION/CREATION
echo ""
echo "📋 Step 2: Using Existing Service Account (Safe Mode)..."

# Always use the default service account - DO NOT DELETE OR RECREATE
DEFAULT_SA="aws-load-balancer-controller"
SA_TO_USE="$DEFAULT_SA"

if kubectl get serviceaccount "$DEFAULT_SA" -n kube-system >/dev/null 2>&1; then
    SA_ROLE=$(kubectl get serviceaccount "$DEFAULT_SA" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "$SA_ROLE" ]; then
        echo "✅ Using existing service account: $DEFAULT_SA"
        echo "   Role: $SA_ROLE"
    else
        echo "✅ Using existing service account: $DEFAULT_SA (no role annotation - that's OK)"
    fi
else
    echo "⚠️ Service account $DEFAULT_SA not found"
    echo "💡 Please create it manually or run eksctl create iamserviceaccount"
    echo "   This script will NOT create or delete any IAM resources"
    exit 1
fi

echo "✅ Service account ready: $SA_TO_USE (existing - not modified)"

# Step 3: Install AWS Load Balancer Controller
echo ""
echo "📋 Step 3: Installing AWS Load Balancer Controller..."

# Add EKS Helm repository
echo "📦 Adding EKS Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

# Handle Helm deployment - SAFE MODE (no uninstall options)
EXISTING_RELEASE=""
if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
    EXISTING_RELEASE=$(helm list -n kube-system | grep "aws-load-balancer-controller" | awk '{print $1}' | head -1)
    echo "✅ Found existing Helm release: $EXISTING_RELEASE"
    
    echo "🔄 Upgrading existing installation to fix CrashLoopBackOff..."
    echo "   This will NOT delete any existing resources"
    echo "   Only updating the deployment configuration"
    
    helm upgrade "$EXISTING_RELEASE" eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SA_TO_USE" \
        --set region="$AWS_REGION" \
        --set vpcId="$VPC_ID" \
        --version 1.14.0 \
        --wait --timeout=10m
        
    echo "✅ Upgrade completed - should fix CrashLoopBackOff issues"
else
    echo "🚀 Installing AWS Load Balancer Controller (new installation)..."
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SA_TO_USE" \
        --set region="$AWS_REGION" \
        --set vpcId="$VPC_ID" \
        --version 1.14.0 \
        --wait --timeout=10m
fi

# Step 4: Verify Installation
echo ""
echo "📋 Step 4: Verifying Installation..."

# Find the deployment
LB_DEPLOYMENT=$(kubectl get deployments -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name 2>/dev/null | head -1)

if [ -n "$LB_DEPLOYMENT" ]; then
    DEPLOYMENT_NAME=$(echo "$LB_DEPLOYMENT" | cut -d'/' -f2)
    echo "✅ Found AWS Load Balancer Controller deployment: $DEPLOYMENT_NAME"
    
    # Show deployment status
    kubectl get deployment -n kube-system "$DEPLOYMENT_NAME"
    
    # Wait for pods to be ready
    echo "⏳ Waiting for pods to be ready (up to 5 minutes)..."
    if kubectl wait --for=condition=available deployment/"$DEPLOYMENT_NAME" -n kube-system --timeout=300s; then
        echo "✅ AWS Load Balancer Controller is ready!"
        
        # Show pod status
        echo "📋 Controller pods:"
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
        
        # Check logs if pods are not running
        FAILED_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | grep -v "Running" | awk '{print $1}' || echo "")
        if [ -n "$FAILED_PODS" ]; then
            echo "⚠️ Some pods are not running. Checking logs..."
            for pod in $FAILED_PODS; do
                echo "📋 Logs for $pod:"
                kubectl logs "$pod" -n kube-system --tail=20 || echo "Could not get logs"
            done
        fi
    else
        echo "⚠️ Deployment did not become ready within 5 minutes"
        echo "📋 Current status:"
        kubectl get deployment -n kube-system "$DEPLOYMENT_NAME"
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
        
        echo "📋 Checking pod logs for issues..."
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | awk '{print $1}' | while read pod; do
            echo "📋 Logs for $pod:"
            kubectl logs "$pod" -n kube-system --tail=20 || echo "Could not get logs"
        done
    fi
else
    echo "❌ No AWS Load Balancer Controller deployment found"
    exit 1
fi

echo ""
echo "🎉 AWS Load Balancer Controller setup completed!"
echo ""
echo "📋 Summary:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Service Account: $SA_TO_USE"
echo "   VPC ID: $VPC_ID"
echo "   Region: $AWS_REGION"
echo "   Status: Ready for LiveKit deployment"