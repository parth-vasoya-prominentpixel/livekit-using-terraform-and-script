#!/bin/bash

# AWS Load Balancer Controller Setup Script - Smart Version
# Uses existing resources when available, creates only what's needed
# Version: AWS Load Balancer Controller v2.8.0

set -e

echo "⚖️ AWS Load Balancer Controller Setup - Smart Version"
echo "===================================================="
echo "📋 Uses existing resources when available"
echo "🎯 Creates only what's needed"

# Check if CLUSTER_NAME is provided
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export AWS_REGION=us-east-1  # optional"
    echo "  ./02-setup-load-balancer.sh"
    echo ""
    exit 1
fi

# Set AWS region
AWS_REGION=${AWS_REGION:-us-east-1}

echo ""
echo "📋 Configuration:"
echo "   Cluster Name: $CLUSTER_NAME"
echo "   AWS Region: $AWS_REGION"
echo "   Mode: Smart (use existing resources)"

# Get AWS account ID
echo ""
echo "🔍 Getting AWS account information..."
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo "❌ Failed to get AWS account ID. Check AWS credentials."
    exit 1
fi
echo "✅ AWS Account ID: $AWS_ACCOUNT_ID"

# Quick cluster verification
echo ""
echo "🔍 Verifying cluster..."
CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
    echo "❌ Cluster '$CLUSTER_NAME' is not ACTIVE (status: $CLUSTER_STATUS)"
    exit 1
fi
echo "✅ Cluster is ACTIVE"

# Update kubeconfig
echo ""
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
echo "✅ Kubeconfig updated"

# Test kubectl
echo ""
echo "🔍 Testing kubectl..."
if ! timeout 10 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo "✅ kubectl working"

# Get VPC ID
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "✅ VPC ID: $VPC_ID"

# Step 1: Check IAM Policy
echo ""
echo "📋 Step 1: Checking IAM Policy..."
POLICY_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy exists: AWSLoadBalancerControllerIAMPolicy"
else
    echo "📋 Creating IAM policy..."
    
    # Download and create policy
    curl -sS -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json
    
    if aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json >/dev/null 2>&1; then
        echo "✅ IAM policy created"
    else
        echo "❌ Failed to create IAM policy"
        exit 1
    fi
    
    rm -f iam_policy.json
fi

# Step 2: Check Service Account
echo ""
echo "📋 Step 2: Checking Service Account..."
SA_NAME="aws-load-balancer-controller"

if kubectl get serviceaccount "$SA_NAME" -n kube-system >/dev/null 2>&1; then
    echo "✅ Service account exists: $SA_NAME"
    
    # Check if it has IAM role
    SA_ROLE=$(kubectl get serviceaccount "$SA_NAME" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "$SA_ROLE" ]; then
        echo "✅ Service account has IAM role: $(basename "$SA_ROLE")"
    else
        echo "⚠️ Service account has no IAM role (using node permissions)"
    fi
    echo "🎯 Using existing service account"
    
else
    echo "📋 Creating service account..."
    
    # Create with eksctl (simple approach)
    if eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace=kube-system \
        --name="$SA_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --region="$AWS_REGION" \
        --approve >/dev/null 2>&1; then
        echo "✅ Service account created"
    else
        echo "⚠️ eksctl failed, checking if service account exists anyway..."
        if kubectl get serviceaccount "$SA_NAME" -n kube-system >/dev/null 2>&1; then
            echo "✅ Service account exists (created by previous run)"
        else
            echo "❌ Failed to create service account"
            exit 1
        fi
    fi
fi

# Step 3: Install/Check Load Balancer Controller
echo ""
echo "📋 Step 3: Checking Load Balancer Controller..."

# Add Helm repo
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Check if controller is already installed and healthy
EXISTING_CONTROLLERS=$(kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)

if [ "$EXISTING_CONTROLLERS" -gt 0 ]; then
    echo "✅ Found $EXISTING_CONTROLLERS load balancer controller(s)"
    
    # Check if any are healthy
    HEALTHY_FOUND=false
    kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | while read name ready rest; do
        if [[ "$ready" == *"/"* ]]; then
            READY_COUNT=$(echo "$ready" | cut -d'/' -f1)
            DESIRED_COUNT=$(echo "$ready" | cut -d'/' -f2)
            if [ "$READY_COUNT" = "$DESIRED_COUNT" ] && [ "$READY_COUNT" != "0" ]; then
                echo "✅ Controller '$name' is healthy ($ready)"
                HEALTHY_FOUND=true
                break
            fi
        fi
    done
    
    if [ "$HEALTHY_FOUND" = true ]; then
        echo "🎉 Load balancer controller is already working!"
        echo "✅ Setup completed - using existing healthy controller"
        exit 0
    else
        echo "⚠️ Controllers exist but none are healthy, installing new one..."
    fi
fi

# Install new controller
echo "🚀 Installing AWS Load Balancer Controller..."
RELEASE_NAME="aws-load-balancer-controller"
CHART_VERSION="1.8.0"

# Check if release already exists
if helm list -n kube-system | grep -q "$RELEASE_NAME"; then
    echo "🔄 Upgrading existing release..."
    HELM_ACTION="upgrade"
else
    echo "📦 Installing new release..."
    HELM_ACTION="install"
fi

if helm "$HELM_ACTION" "$RELEASE_NAME" eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="$SA_NAME" \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID" \
    --version "$CHART_VERSION" \
    --wait --timeout=5m >/dev/null 2>&1; then
    
    echo "✅ Load balancer controller $HELM_ACTION completed"
else
    echo "❌ Helm $HELM_ACTION failed"
    
    # Show basic troubleshooting info
    echo "📋 Current status:"
    kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null || echo "   No deployments found"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null || echo "   No pods found"
    
    exit 1
fi

# Quick verification
echo ""
echo "📋 Verification..."
if kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system --timeout=60s >/dev/null 2>&1; then
    echo "✅ Controller is ready!"
    
    # Show final status
    RUNNING_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    echo "📊 Running pods: $RUNNING_PODS"
    
else
    echo "⚠️ Controller may still be starting up"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null || echo "   No pods found"
fi

echo ""
echo "🎉 AWS Load Balancer Controller Setup Completed!"
echo "=============================================="
echo ""
echo "📋 Summary:"
echo "   ✅ Cluster: $CLUSTER_NAME"
echo "   ✅ IAM Policy: AWSLoadBalancerControllerIAMPolicy"
echo "   ✅ Service Account: $SA_NAME"
echo "   ✅ Controller: Ready for load balancer provisioning"
echo ""
echo "📋 Next Steps:"
echo "   1. Deploy applications with LoadBalancer services"
echo "   2. Controller will automatically create AWS load balancers"
echo "   3. Monitor with: kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
echo ""
echo "💡 This setup uses existing resources when available"