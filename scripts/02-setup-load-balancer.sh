#!/bin/bash

# Script to install AWS Load Balancer Controller
set -e

echo "🚀 Setting up AWS Load Balancer Controller..."

# Get cluster info from terraform or environment variables
cd "$(dirname "$0")/../resources"

# Use environment variables if available (from CI/CD), otherwise get from terraform
if [ -n "$CLUSTER_NAME" ] && [ -n "$REGION" ] && [ -n "$VPC_ID" ]; then
    echo "📝 Using environment variables for cluster info"
else
    echo "📝 Getting cluster info from Terraform outputs..."
    CLUSTER_NAME=$(terraform output -raw cluster_name)
    REGION=${AWS_REGION:-us-east-1}  # Use AWS_REGION env var or default
    VPC_ID=$(terraform output -raw vpc_id)
fi

echo "📝 Using Cluster: $CLUSTER_NAME"
echo "🌍 Region: $REGION"
echo "🏠 VPC ID: $VPC_ID"

# Step 1: Create IAM OIDC identity provider
echo "🔐 Creating IAM OIDC identity provider..."
eksctl utils associate-iam-oidc-provider --region=$REGION --cluster=$CLUSTER_NAME --approve

# Step 2: Download IAM policy
echo "📄 Downloading IAM policy for AWS Load Balancer Controller..."
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json

# Step 3: Create IAM policy
echo "🔧 Creating IAM policy..."
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json || echo "Policy already exists, continuing..."

# Step 4: Create IAM role and service account
# Get the IAM role ARN created by Terraform
echo "🔍 Getting Load Balancer Controller IAM role from Terraform..."
cd "$(dirname "$0")/../resources"
LB_CONTROLLER_ROLE_ARN=$(terraform output -raw iam_roles | jq -r '.load_balancer_controller_role_arn')

if [ -z "$LB_CONTROLLER_ROLE_ARN" ] || [ "$LB_CONTROLLER_ROLE_ARN" = "null" ]; then
    echo "❌ Could not get Load Balancer Controller IAM role ARN from Terraform"
    exit 1
fi

echo "✅ Using IAM role: $LB_CONTROLLER_ROLE_ARN"

# Create service account with the Terraform-created IAM role
echo "👤 Creating service account for AWS Load Balancer Controller..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: $LB_CONTROLLER_ROLE_ARN
EOF

# Step 5: Install AWS Load Balancer Controller using Helm
echo "📦 Adding EKS Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo "🚀 Installing AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$VPC_ID

# Step 6: Verify installation
echo "🔍 Verifying AWS Load Balancer Controller installation..."
kubectl get deployment -n kube-system aws-load-balancer-controller

echo "✅ AWS Load Balancer Controller setup complete!"
echo "Next step: Run ./03-deploy-livekit.sh"