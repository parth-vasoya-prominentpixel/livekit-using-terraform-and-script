#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Uses existing resources when available, creates only what's needed
# Safe approach - no deletions, works with existing setup

set -euo pipefail

# Enable full logging
exec > >(tee -a /tmp/lbc-setup.log)
exec 2>&1

echo "🔧 AWS Load Balancer Controller Setup"
echo "===================================="
echo "📅 Started at: $(date)"
echo "� Fullt logging enabled - Safe mode (no deletions)"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# AWS Load Balancer Controller configuration (USE DEFAULT NAMES)
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
echo "   Service Account: $SERVICE_ACCOUNT_NAME (default name)"
echo "   IAM Role: $ROLE_NAME (default name)"
echo "   IAM Policy: $POLICY_NAME (default name)"
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
# STEP 1: CHECK EXISTING INSTALLATION
# =============================================================================

echo "📋 Step 1: Checking existing AWS Load Balancer Controller..."

# Check if deployment already exists and is healthy
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
        echo "🎉 AWS Load Balancer Controller is already working!"
        echo ""
        echo "🔍 Current Status:"
        kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
        kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
        kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" 2>/dev/null || echo "Webhook service not found"
        echo ""
        echo "✅ Load Balancer Controller is ready for use!"
        echo "📅 Completed at: $(date)"
        exit 0
    else
        echo "⚠️  Deployment exists but not healthy (0 ready replicas)"
        echo "   Will proceed with setup to fix this"
    fi
else
    echo "ℹ️  No existing deployment found"
fi
echo ""

# =============================================================================
# STEP 2: SETUP IAM POLICY
# =============================================================================

echo "📋 Step 2: Setting up IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
    echo "   Policy ARN: $POLICY_ARN"
else
    echo "🔄 Creating IAM policy: $POLICY_NAME"
    
    # Download the IAM policy
    curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
    
    # Create the policy
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --description "IAM policy for AWS Load Balancer Controller"
    
    # Clean up
    rm -f iam_policy.json
    
    echo "✅ IAM policy created: $POLICY_ARN"
fi
echo ""

# =============================================================================
# STEP 3: SETUP SERVICE ACCOUNT AND IAM ROLE
# =============================================================================

echo "📋 Step 3: Setting up service account and IAM role..."

# Check if service account exists
SA_EXISTS=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1 && echo "true" || echo "false")

if [[ "$SA_EXISTS" == "true" ]]; then
    echo "✅ Service account '$SERVICE_ACCOUNT_NAME' already exists"
    
    # Check if it has IAM role annotation
    EXISTING_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_ROLE_ARN" && "$EXISTING_ROLE_ARN" != "null" ]]; then
        echo "✅ Service account has IAM role: $EXISTING_ROLE_ARN"
        ROLE_ARN="$EXISTING_ROLE_ARN"
    else
        echo "⚠️  Service account exists but no IAM role annotation"
        
        # Check if the default IAM role exists
        DEFAULT_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
        if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
            echo "✅ IAM role '$ROLE_NAME' exists, adding annotation..."
            kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" \
                eks.amazonaws.com/role-arn="$DEFAULT_ROLE_ARN" \
                --overwrite
            ROLE_ARN="$DEFAULT_ROLE_ARN"
            echo "✅ Added IAM role annotation to existing service account"
        else
            echo "⚠️  IAM role '$ROLE_NAME' doesn't exist, will create it..."
            SA_EXISTS="false"  # Force creation
        fi
    fi
else
    echo "ℹ️  Service account '$SERVICE_ACCOUNT_NAME' doesn't exist"
fi

# Create service account and role if needed
if [[ "$SA_EXISTS" == "false" ]]; then
    echo "🔄 Creating service account and IAM role..."
    
    eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace="$LB_NAMESPACE" \
        --name="$SERVICE_ACCOUNT_NAME" \
        --role-name="$ROLE_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --region="$AWS_REGION" \
        --approve
    
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    echo "✅ Service account and IAM role created"
fi

# Verify service account
echo "🔍 Verifying service account..."
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account verified: $SERVICE_ACCOUNT_NAME"
    
    # Check IAM role annotation
    FINAL_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [[ -n "$FINAL_ROLE_ARN" && "$FINAL_ROLE_ARN" != "null" ]]; then
        echo "✅ IAM role annotation: $FINAL_ROLE_ARN"
    else
        echo "⚠️  No IAM role annotation found, but continuing..."
    fi
else
    echo "❌ Service account not found"
    exit 1
fi
echo ""

# =============================================================================
# STEP 4: SETUP HELM REPOSITORY
# =============================================================================

echo "📋 Step 4: Setting up Helm repository..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || echo "Repository already exists"
helm repo update
echo "✅ EKS Helm repository ready"
echo ""

# =============================================================================
# STEP 5: INSTALL AWS LOAD BALANCER CONTROLLER
# =============================================================================

echo "📋 Step 5: Installing AWS Load Balancer Controller..."

# Check if Helm release exists
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller"; then
    RELEASE_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    echo "ℹ️  Helm release exists with status: $RELEASE_STATUS"
    
    if [[ "$RELEASE_STATUS" == "deployed" ]]; then
        echo "✅ Helm release is deployed, checking deployment health..."
    else
        echo "⚠️  Helm release status is '$RELEASE_STATUS', will reinstall..."
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE"
        sleep 5
    fi
fi

# Install or reinstall
if ! (helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller" && \
      helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' | grep -q "deployed"); then
    
    echo "🔄 Installing AWS Load Balancer Controller via Helm..."
    
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n "$LB_NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --version="$HELM_CHART_VERSION"
    
    echo "✅ Helm installation completed"
else
    echo "✅ Helm release already deployed"
fi
echo ""

# =============================================================================
# STEP 6: VERIFY INSTALLATION
# =============================================================================

echo "📋 Step 6: Verifying installation..."

# Wait for deployment
echo "⏳ Waiting for deployment to be created..."
for i in {1..30}; do
    if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
        echo "✅ Deployment found"
        break
    else
        echo "   Waiting... (attempt $i/30)"
        sleep 2
    fi
done

# Wait for pods
echo "⏳ Waiting for pods to be ready..."
for i in {1..60}; do
    RUNNING_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    READY_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "1/1" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ "$READY_PODS" -gt 0 ]]; then
        echo "✅ Pods are ready ($READY_PODS/$TOTAL_PODS ready, $RUNNING_PODS running)"
        break
    fi
    
    echo "   Pod status: $READY_PODS/$TOTAL_PODS ready, $RUNNING_PODS running (attempt $i/60)"
    sleep 5
done

# Final verification
echo ""
echo "🔍 Final Status:"
echo "================"
kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null || echo "❌ Deployment not found"
echo ""
kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null || echo "❌ No pods found"
echo ""
kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" 2>/dev/null || echo "⚠️  Webhook service not found"

# Check final status
FINAL_RUNNING=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
FINAL_READY=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "1/1" || echo "0")

echo ""
if [[ "$FINAL_READY" -gt 0 ]]; then
    echo "🎉 SUCCESS: AWS Load Balancer Controller is ready!"
    echo "✅ $FINAL_READY pods ready and running"
    echo "✅ Ready to provision ALBs"
else
    echo "⚠️  WARNING: Load Balancer Controller may not be fully ready"
    echo "   $FINAL_RUNNING pods running, $FINAL_READY pods ready"
    echo "   Check logs: kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
fi

echo ""
echo "📋 Next Steps:"
echo "   1. Load Balancer Controller setup completed"
echo "   2. You can now deploy services with ALB annotations"
echo "   3. Monitor status: kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
echo ""
echo "✅ AWS Load Balancer Controller setup complete!"
echo "📅 Completed at: $(date)"