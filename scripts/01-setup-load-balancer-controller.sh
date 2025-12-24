#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Following EXACT AWS Documentation: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
# Handles all cases properly - existing resources, new clusters, etc.

set -euo pipefail

echo "🔧 AWS Load Balancer Controller Setup"
echo "===================================="
echo "📅 Started at: $(date)"
echo "📋 Following official AWS documentation exactly"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# AWS Load Balancer Controller configuration (EXACT AWS DEFAULTS)
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
LB_NAMESPACE="kube-system"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
HELM_CHART_VERSION="1.14.0"

# Validate required environment variables
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Environment: $ENVIRONMENT"
echo "   Service Account: $SERVICE_ACCOUNT_NAME"
echo "   IAM Role: $ROLE_NAME"
echo "   IAM Policy: $POLICY_NAME"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verify required tools
echo "🔧 Verifying required tools..."
for tool in aws kubectl helm eksctl jq curl; do
    if command_exists "$tool"; then
        echo "✅ $tool: available"
    else
        echo "❌ $tool: not found"
        exit 1
    fi
done
echo ""

# Get AWS account ID
echo "🔐 Getting AWS account information..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✅ Account ID: $ACCOUNT_ID"
echo ""

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
echo "✅ Kubeconfig updated"
echo ""

# Verify cluster connectivity
echo "🔍 Verifying cluster connectivity..."
if kubectl get nodes >/dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    echo "✅ Connected to cluster with $NODE_COUNT nodes"
else
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo ""

# =============================================================================
# STEP 0: CHECK IF ALREADY INSTALLED AND WORKING
# =============================================================================

echo "📋 Step 0: Checking if AWS Load Balancer Controller is already working..."

# Check if deployment exists and is healthy
if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    # Handle null values
    if [[ "${READY_REPLICAS}" == "null" || "${READY_REPLICAS}" == "" ]]; then
        READY_REPLICAS="0"
    fi
    if [[ "${DESIRED_REPLICAS}" == "null" || "${DESIRED_REPLICAS}" == "" ]]; then
        DESIRED_REPLICAS="0"
    fi
    
    echo "ℹ️  Found existing deployment: ${READY_REPLICAS}/${DESIRED_REPLICAS} replicas ready"
    
    if [[ "${READY_REPLICAS}" -gt 0 ]]; then
        echo "🎉 AWS Load Balancer Controller is already working perfectly!"
        echo ""
        echo "🔍 Current Status:"
        kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
        kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
        kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" 2>/dev/null || echo "Webhook service: checking..."
        echo ""
        echo "✅ Load Balancer Controller is ready for use!"
        echo "📅 Completed at: $(date)"
        exit 0
    else
        echo "⚠️  Deployment exists but not healthy, will fix it"
    fi
else
    echo "ℹ️  No existing deployment found, will install fresh"
fi
echo ""

# =============================================================================
# STEP 1: CREATE IAM ROLE USING EKSCTL (EXACT AWS DOCUMENTATION)
# =============================================================================

echo "📋 Step 1: Create IAM Role using eksctl (AWS Documentation)"
echo "==========================================================="

# Sub-step 1a: Download IAM policy
echo "📋 Step 1a: Download IAM policy for AWS Load Balancer Controller..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
    echo "   Policy ARN: $POLICY_ARN"
else
    echo "🔄 Downloading and creating IAM policy..."
    
    # Download IAM policy (exact AWS documentation command)
    curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json
    
    # Create IAM policy (exact AWS documentation command)
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json
    
    # Clean up
    rm -f iam_policy.json
    
    echo "✅ IAM policy created: $POLICY_ARN"
fi
echo ""

# Sub-step 1b: Create IAM service account
echo "📋 Step 1b: Create IAM service account using eksctl..."

# Check if service account already exists
SA_EXISTS="false"
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "ℹ️  Service account '$SERVICE_ACCOUNT_NAME' already exists"
    
    # Check if it has proper IAM role annotation
    EXISTING_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_ROLE_ARN" && "$EXISTING_ROLE_ARN" != "null" ]]; then
        echo "✅ Service account has IAM role: $EXISTING_ROLE_ARN"
        SA_EXISTS="true"
        
        # Verify the role exists in AWS
        ROLE_NAME_FROM_ARN=$(echo "$EXISTING_ROLE_ARN" | cut -d'/' -f2)
        if aws iam get-role --role-name "$ROLE_NAME_FROM_ARN" >/dev/null 2>&1; then
            echo "✅ IAM role verified in AWS: $ROLE_NAME_FROM_ARN"
        else
            echo "⚠️  IAM role not found in AWS, will recreate"
            SA_EXISTS="false"
        fi
    else
        echo "⚠️  Service account exists but no IAM role annotation"
        SA_EXISTS="false"
    fi
fi

# Create or fix service account
if [[ "$SA_EXISTS" == "false" ]]; then
    echo "🔄 Creating/fixing service account with IAM role..."
    
    # Use exact AWS documentation command with --override-existing-serviceaccounts
    echo "📋 Running eksctl command (AWS documentation):"
    echo "eksctl create iamserviceaccount \\"
    echo "    --cluster=$CLUSTER_NAME \\"
    echo "    --namespace=kube-system \\"
    echo "    --name=aws-load-balancer-controller \\"
    echo "    --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \\"
    echo "    --override-existing-serviceaccounts \\"
    echo "    --region $AWS_REGION \\"
    echo "    --approve"
    echo ""
    
    eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --attach-policy-arn="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy" \
        --override-existing-serviceaccounts \
        --region "$AWS_REGION" \
        --approve
    
    echo "✅ eksctl command completed"
fi

# Verify service account exists and is properly configured
echo "🔍 Verifying service account configuration..."
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account exists: $SERVICE_ACCOUNT_NAME"
    
    # Check IAM role annotation
    FINAL_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [[ -n "$FINAL_ROLE_ARN" && "$FINAL_ROLE_ARN" != "null" ]]; then
        echo "✅ IAM role annotation: $FINAL_ROLE_ARN"
        
        # Verify role exists in AWS
        ROLE_NAME_FROM_ARN=$(echo "$FINAL_ROLE_ARN" | cut -d'/' -f2)
        if aws iam get-role --role-name "$ROLE_NAME_FROM_ARN" >/dev/null 2>&1; then
            echo "✅ IAM role verified in AWS: $ROLE_NAME_FROM_ARN"
        else
            echo "❌ IAM role not found in AWS: $ROLE_NAME_FROM_ARN"
            exit 1
        fi
    else
        echo "❌ Service account missing IAM role annotation"
        echo "🔍 Service account details:"
        kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o yaml
        exit 1
    fi
else
    echo "❌ Service account not found: $SERVICE_ACCOUNT_NAME"
    echo "🔍 Available service accounts in $LB_NAMESPACE:"
    kubectl get serviceaccounts -n "$LB_NAMESPACE"
    exit 1
fi
echo ""

# =============================================================================
# STEP 2: INSTALL AWS LOAD BALANCER CONTROLLER (EXACT AWS DOCUMENTATION)
# =============================================================================

echo "📋 Step 2: Install AWS Load Balancer Controller (AWS Documentation)"
echo "=================================================================="

# Sub-step 2a: Add eks-charts Helm repository
echo "📋 Step 2a: Add eks-charts Helm repository..."
echo "🔄 Running: helm repo add eks https://aws.github.io/eks-charts"
helm repo add eks https://aws.github.io/eks-charts

echo "🔄 Running: helm repo update eks"
helm repo update eks
echo "✅ Helm repository configured"
echo ""

# Sub-step 2b: Install AWS Load Balancer Controller
echo "📋 Step 2b: Install AWS Load Balancer Controller..."

# Check if Helm release already exists
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller"; then
    RELEASE_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    echo "ℹ️  Helm release exists with status: $RELEASE_STATUS"
    
    if [[ "$RELEASE_STATUS" != "deployed" ]]; then
        echo "⚠️  Helm release status is '$RELEASE_STATUS', removing and reinstalling..."
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE"
        sleep 5
    else
        echo "ℹ️  Helm release is deployed, checking if upgrade needed..."
    fi
fi

# Install or upgrade using exact AWS documentation command
echo "🔄 Installing AWS Load Balancer Controller using Helm..."
echo "📋 Running exact AWS documentation command:"
echo "helm install aws-load-balancer-controller eks/aws-load-balancer-controller \\"
echo "  -n kube-system \\"
echo "  --set clusterName=$CLUSTER_NAME \\"
echo "  --set serviceAccount.create=false \\"
echo "  --set serviceAccount.name=aws-load-balancer-controller \\"
echo "  --version 1.14.0"
echo ""

# Check if already installed
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller" && \
   helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' | grep -q "deployed"; then
    echo "✅ Helm release already deployed, checking if working..."
else
    # Install fresh
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --version 1.14.0
    
    echo "✅ Helm installation completed"
fi
echo ""

# =============================================================================
# STEP 3: VERIFY CONTROLLER IS INSTALLED (EXACT AWS DOCUMENTATION)
# =============================================================================

echo "📋 Step 3: Verify that the controller is installed (AWS Documentation)"
echo "===================================================================="

echo "🔄 Running: kubectl get deployment -n kube-system aws-load-balancer-controller"
echo ""

# Wait for deployment to exist
echo "⏳ Waiting for deployment to be created..."
for i in {1..30}; do
    if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
        echo "✅ Deployment found"
        break
    else
        echo "   Waiting for deployment... (attempt $i/30)"
        sleep 2
    fi
done

# Verify deployment exists
if ! kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "❌ Deployment not found after installation"
    echo "🔍 Checking Helm releases:"
    helm list -n "$LB_NAMESPACE"
    echo "🔍 Checking events:"
    kubectl get events -n "$LB_NAMESPACE" --sort-by='.lastTimestamp' | tail -10
    exit 1
fi

# Show deployment status (exact AWS documentation command)
echo "📋 Deployment Status:"
kubectl get deployment -n kube-system aws-load-balancer-controller
echo ""

# Wait for pods to be ready
echo "⏳ Waiting for pods to be ready..."
for i in {1..60}; do  # 5 minutes max
    READY_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "   Pod status: $READY_PODS/$TOTAL_PODS ready (attempt $i/60)"
    
    if [[ "$READY_PODS" -gt 0 && "$READY_PODS" -eq "$TOTAL_PODS" ]]; then
        echo "✅ All pods are ready!"
        break
    fi
    
    # Show pod details every 10 attempts
    if [[ $((i % 10)) -eq 0 ]]; then
        echo "🔍 Current pod status:"
        kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    fi
    
    sleep 5
done

# Final verification
echo ""
echo "🔍 Final Verification:"
echo "====================="

# Show deployment (AWS documentation verification)
echo "📋 Deployment Status:"
kubectl get deployment -n kube-system aws-load-balancer-controller
echo ""

# Show pods
echo "📋 Pod Status:"
kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
echo ""

# Check webhook service
echo "📋 Webhook Service:"
kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" 2>/dev/null || echo "⚠️  Webhook service not found (may still be starting)"
echo ""

# Final status check
FINAL_READY=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
FINAL_TOTAL=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")

if [[ "$FINAL_READY" -gt 0 && "$FINAL_READY" -eq "$FINAL_TOTAL" ]]; then
    echo "🎉 SUCCESS: AWS Load Balancer Controller is installed and ready!"
    echo "✅ $FINAL_READY/$FINAL_TOTAL pods ready and running"
    echo "✅ Controller can now provision ALBs and NLBs"
    echo ""
    echo "📋 Expected Output (AWS Documentation):"
    echo "NAME                           READY   UP-TO-DATE   AVAILABLE   AGE"
    kubectl get deployment -n kube-system aws-load-balancer-controller --no-headers
    echo ""
    echo "✅ Installation completed successfully!"
    echo "📅 Completed at: $(date)"
    exit 0
else
    echo "❌ FAILED: AWS Load Balancer Controller is not ready"
    echo "   $FINAL_READY/$FINAL_TOTAL pods ready"
    echo ""
    echo "🔍 Troubleshooting Information:"
    echo "================================"
    
    # Show deployment details
    echo "📋 Deployment Details:"
    kubectl describe deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
    echo ""
    
    # Show pod details
    echo "📋 Pod Details:"
    kubectl describe pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    echo ""
    
    # Show recent events
    echo "📋 Recent Events:"
    kubectl get events -n "$LB_NAMESPACE" --sort-by='.lastTimestamp' | tail -15
    echo ""
    
    echo "❌ Installation failed!"
    echo "📅 Failed at: $(date)"
    exit 1
fi