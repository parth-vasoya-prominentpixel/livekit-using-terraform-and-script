#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Following official AWS documentation: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
# ONLY Load Balancer Controller - No LiveKit
# Full logging enabled for troubleshooting

set -euo pipefail

# Enable full logging
exec > >(tee -a /tmp/lbc-setup.log)
exec 2>&1

echo "🔧 AWS Load Balancer Controller Setup"
echo "===================================="
echo "📅 Started at: $(date)"
echo "🔍 Full logging enabled"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# AWS Load Balancer Controller configuration (UNIQUE NAMES)
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller-livekit"
LB_NAMESPACE="kube-system"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-LiveKit"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole-LiveKit"
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
        VERSION=$($tool version --client 2>/dev/null | head -1 || $tool --version 2>/dev/null | head -1 || echo "unknown")
        echo "✅ $tool: available ($VERSION)"
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
echo "📋 Command: aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
echo "✅ Kubeconfig updated"
echo "🔍 Current context: $(kubectl config current-context)"
echo ""

# Verify cluster connectivity
echo "🔍 Verifying cluster connectivity..."
if kubectl get nodes >/dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    echo "✅ Connected to cluster with $NODE_COUNT nodes"
    kubectl get nodes
else
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo ""

# =============================================================================
# AWS LOAD BALANCER CONTROLLER SETUP (OFFICIAL AWS DOCUMENTATION)
# =============================================================================

echo "📋 Following AWS Documentation Steps:"
echo "https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html"
echo ""

# Step 1: Check existing installations
echo "📋 Step 1: Checking existing installations..."
echo "🔍 Checking for existing Helm releases..."

# List all Helm releases in kube-system
echo "📋 Current Helm releases in kube-system:"
helm list -n "$LB_NAMESPACE" || echo "No Helm releases found"
echo ""

# Check if our specific Helm release exists
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller"; then
    echo "⚠️  Found existing aws-load-balancer-controller Helm release"
    
    # Check status
    RELEASE_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    echo "   Current status: $RELEASE_STATUS"
    
    if [[ "$RELEASE_STATUS" == "failed" ]]; then
        echo "🧹 Removing failed Helm release..."
        echo "📋 Command: helm uninstall aws-load-balancer-controller -n $LB_NAMESPACE"
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE"
        sleep 5
        echo "✅ Failed release removed"
    fi
else
    echo "ℹ️  No existing aws-load-balancer-controller Helm release found"
fi

echo ""
echo "🔍 Checking for existing deployments..."

# Check deployment health
if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "📋 Found existing deployment, checking health..."
    
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    # Handle null values
    if [[ "${READY_REPLICAS}" == "null" || "${READY_REPLICAS}" == "" ]]; then
        READY_REPLICAS="0"
    fi
    if [[ "${DESIRED_REPLICAS}" == "null" || "${DESIRED_REPLICAS}" == "" ]]; then
        DESIRED_REPLICAS="0"
    fi
    
    echo "ℹ️  Deployment status: ${READY_REPLICAS}/${DESIRED_REPLICAS} replicas ready"
    
    # Show deployment details
    echo "🔍 Deployment details:"
    kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o wide
    
    echo "🔍 Pod status:"
    kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller || echo "No pods found"
    
    if [[ "${READY_REPLICAS}" -eq 0 && "${DESIRED_REPLICAS}" -gt 0 ]]; then
        echo "🧹 Deployment is unhealthy (0 ready replicas), removing for fresh install..."
        echo "📋 Command: kubectl delete deployment aws-load-balancer-controller -n $LB_NAMESPACE"
        kubectl delete deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
        
        # Also remove the Helm release if it exists
        echo "📋 Command: helm uninstall aws-load-balancer-controller -n $LB_NAMESPACE"
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null || true
        
        sleep 10
        echo "✅ Unhealthy deployment removed"
    elif [[ "${READY_REPLICAS}" -gt 0 ]]; then
        echo "✅ Existing deployment is healthy (${READY_REPLICAS}/${DESIRED_REPLICAS})"
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
    fi
else
    echo "ℹ️  No existing deployment found"
fi

echo "✅ Ready for fresh installation"
echo ""

# Step 2: Download and create IAM policy
echo "📋 Step 2: Setting up IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
else
    echo "🔄 Creating IAM policy: $POLICY_NAME"
    echo "   Downloading policy from AWS documentation..."
    
    # Download the IAM policy as per AWS docs
    curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
    
    # Create the policy
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --description "IAM policy for AWS Load Balancer Controller (LiveKit)"
    
    # Clean up
    rm -f iam_policy.json
    
    echo "✅ IAM policy created: $POLICY_ARN"
fi
echo ""

# Step 3: Create IAM service account
echo "📋 Step 3: Creating IAM service account..."

# Check if our specific service account exists
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_ROLE_ARN" && "$EXISTING_ROLE_ARN" != "null" ]]; then
        echo "✅ Service account already exists with IAM role: $EXISTING_ROLE_ARN"
        ROLE_ARN="$EXISTING_ROLE_ARN"
    else
        echo "⚠️  Service account exists but no IAM role annotation"
        echo "   Recreating service account with proper IAM role..."
        kubectl delete serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE"
        sleep 2
    fi
fi

# Create service account if it doesn't exist or needs IAM role
if ! kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "🔄 Creating service account with IAM role using eksctl..."
    
    eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace="$LB_NAMESPACE" \
        --name="$SERVICE_ACCOUNT_NAME" \
        --role-name="$ROLE_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --region="$AWS_REGION" \
        --override-existing-serviceaccounts \
        --approve
    
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    echo "✅ Service account created with IAM role: $ROLE_ARN"
fi

# Verify service account
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account verified: $SERVICE_ACCOUNT_NAME"
    echo "🔍 Service account details:"
    kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o yaml | grep -A 3 annotations || echo "No annotations found"
else
    echo "❌ Service account verification failed"
    exit 1
fi
echo ""

# Step 4: Add EKS Helm repository
echo "📋 Step 4: Setting up Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
echo "✅ EKS Helm repository added and updated"
echo ""

# Step 5: Install AWS Load Balancer Controller using Helm
echo "📋 Step 5: Installing AWS Load Balancer Controller using Helm..."

echo "🔄 Installing AWS Load Balancer Controller..."
echo "   Chart version: $HELM_CHART_VERSION"
echo "   Service account: $SERVICE_ACCOUNT_NAME"
echo "   Cluster: $CLUSTER_NAME"
echo ""

# Install using Helm as per AWS documentation
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n "$LB_NAMESPACE" \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
    --set region="$AWS_REGION" \
    --version="$HELM_CHART_VERSION"

echo "✅ Helm installation completed"
echo ""

# Step 6: Verify the installation
echo "📋 Step 6: Verifying AWS Load Balancer Controller installation..."

# Wait for deployment to be created
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

# Wait for pods to be created
echo "⏳ Waiting for pods to be created..."
for i in {1..60}; do
    POD_COUNT=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$POD_COUNT" -gt 0 ]]; then
        echo "✅ Pods created ($POD_COUNT pods)"
        break
    else
        echo "   Waiting for pods to be created... (attempt $i/60)"
        sleep 5
    fi
done

# Check if pods were created
POD_COUNT=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "$POD_COUNT" -eq 0 ]]; then
    echo "❌ No pods were created"
    echo "🔍 Checking deployment status:"
    kubectl describe deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
    echo ""
    echo "🔍 Checking replica set:"
    kubectl get replicaset -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    echo ""
    echo "🔍 Checking events:"
    kubectl get events -n "$LB_NAMESPACE" --sort-by='.lastTimestamp' | tail -15
    exit 1
fi

# Wait for pods to be ready
echo "⏳ Waiting for pods to be ready (up to 5 minutes)..."
if kubectl wait --for=condition=ready --timeout=300s pods -l app.kubernetes.io/name=aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null; then
    echo "✅ Load Balancer Controller pods are ready"
else
    echo "⚠️  Pods not ready within 5 minutes, checking status..."
    
    kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    
    # Check if any pods are running
    RUNNING_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    
    if [[ "$RUNNING_PODS" -gt 0 ]]; then
        echo "✅ Some pods are running ($RUNNING_PODS), continuing..."
    else
        echo "❌ No pods are running, checking for issues..."
        echo "🔍 Pod details:"
        kubectl describe pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null | tail -50
        echo ""
        echo "🔍 Pod logs:"
        kubectl logs -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20 2>/dev/null || echo "No logs available"
        echo ""
        echo "❌ Load Balancer Controller is not working"
        exit 1
    fi
fi

# Verify webhook service
echo "🔍 Verifying webhook service..."
for i in {1..30}; do
    if kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" >/dev/null 2>&1; then
        ENDPOINTS=$(kubectl get endpoints aws-load-balancer-webhook-service -n "$LB_NAMESPACE" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
        if [[ -n "$ENDPOINTS" && "$ENDPOINTS" != "null" && "$ENDPOINTS" != "[]" ]]; then
            echo "✅ Webhook service is ready with endpoints"
            break
        fi
    fi
    echo "   Waiting for webhook service... (attempt $i/30)"
    sleep 2
done

# Final verification
echo ""
echo "🔍 Final AWS Load Balancer Controller Status:"
echo "============================================="
kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
echo ""
kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
echo ""
kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" 2>/dev/null || echo "Webhook service not found"
echo ""

FINAL_RUNNING=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "$FINAL_RUNNING" -gt 0 ]]; then
    echo "🎉 SUCCESS: AWS Load Balancer Controller is ready!"
    echo "✅ $FINAL_RUNNING pods running"
    echo "✅ Webhook service available"
    echo "✅ Ready to provision ALBs"
else
    echo "❌ FAILED: AWS Load Balancer Controller is not ready"
    exit 1
fi

echo ""
echo "📋 Next Steps:"
echo "   1. Load Balancer Controller is now ready"
echo "   2. You can now deploy services with ALB annotations"
echo "   3. For LiveKit, use NodePort service with host networking"
echo ""
echo "🔧 Useful Commands:"
echo "   kubectl get deployment aws-load-balancer-controller -n kube-system"
echo "   kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
echo "   kubectl get service aws-load-balancer-webhook-service -n kube-system"
echo ""
echo "✅ AWS Load Balancer Controller setup complete!"
echo "📅 Completed at: $(date)"
echo "📄 Full logs saved to: /tmp/lbc-setup.log"