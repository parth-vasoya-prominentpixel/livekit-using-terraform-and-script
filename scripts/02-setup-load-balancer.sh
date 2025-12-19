#!/bin/bash

# Script to setup AWS Load Balancer Controller on EKS
set -e

echo "⚖️ Setting up AWS Load Balancer Controller..."

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

# Update kubeconfig with retry
echo "🔧 Updating kubeconfig..."
for i in {1..3}; do
    if aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME; then
        echo "✅ Kubeconfig updated successfully"
        break
    else
        echo "⚠️ Attempt $i failed, retrying in 10 seconds..."
        sleep 10
    fi
done

# Test cluster connectivity
echo "🔍 Testing cluster connectivity..."
for i in {1..5}; do
    if kubectl get nodes >/dev/null 2>&1; then
        echo "✅ Cluster is accessible"
        kubectl get nodes
        break
    else
        echo "⚠️ Cluster not accessible, waiting 30 seconds... (attempt $i/5)"
        sleep 30
    fi
done

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "📋 AWS Account ID: $ACCOUNT_ID"

# Check if IAM policy exists, create if not
echo "📋 Checking IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn $POLICY_ARN >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_ARN"
else
    echo "📋 Creating IAM policy..."
    curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
    
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json
    
    echo "✅ IAM policy created: $POLICY_ARN"
fi

# Check if service account already exists
echo "🔍 Checking if service account exists..."
if kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    echo "✅ Service account already exists"
else
    echo "🔧 Creating IAM service account..."
    
    # Check if IAM role exists
    ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
    if aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
        echo "⚠️ IAM role $ROLE_NAME already exists, deleting service account first..."
        eksctl delete iamserviceaccount \
            --cluster=$CLUSTER_NAME \
            --namespace=kube-system \
            --name=aws-load-balancer-controller \
            --region=$AWS_REGION || true
    fi
    
    # Create new service account
    eksctl create iamserviceaccount \
        --cluster=$CLUSTER_NAME \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --role-name $ROLE_NAME \
        --attach-policy-arn=$POLICY_ARN \
        --approve \
        --region=$AWS_REGION
    
    echo "✅ IAM service account created"
fi

# Add EKS Helm repository
echo "📦 Adding EKS Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Check if Load Balancer Controller is already installed
echo "🔍 Checking if Load Balancer Controller is installed..."
if helm list -n kube-system | grep -q aws-load-balancer-controller; then
    echo "✅ AWS Load Balancer Controller already installed, upgrading..."
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=$CLUSTER_NAME \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set region=$AWS_REGION
else
    echo "🚀 Installing AWS Load Balancer Controller..."
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=$CLUSTER_NAME \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set region=$AWS_REGION
fi

# Wait for deployment to be ready
echo "⏳ Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system

# Verify installation
echo "✅ Verifying installation..."
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo "🎉 AWS Load Balancer Controller setup completed successfully!"