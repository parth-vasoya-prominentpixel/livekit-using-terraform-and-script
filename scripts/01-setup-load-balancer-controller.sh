#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Following AWS Documentation: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
# Proper approach without problematic eksctl commands

set -euo pipefail

echo "🔧 AWS Load Balancer Controller Setup"
echo "===================================="
echo "📅 Started at: $(date)"
echo "📋 Following AWS documentation step by step"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# AWS Load Balancer Controller configuration
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
for tool in aws kubectl helm curl; do
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

# Get VPC ID from cluster (CRITICAL FIX for metadata issues)
echo "🔍 Getting VPC information from cluster..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "✅ VPC ID: $VPC_ID"
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
# CHECK IF ALREADY INSTALLED AND WORKING
# =============================================================================

echo "📋 Checking if AWS Load Balancer Controller is already working..."

if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
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
        echo ""
        echo "✅ Load Balancer Controller is ready!"
        echo "📅 Completed at: $(date)"
        exit 0
    else
        echo "⚠️  Deployment exists but not healthy, will fix it"
    fi
else
    echo "ℹ️  No existing deployment found"
fi
echo ""

# =============================================================================
# STEP 1: CREATE IAM POLICY
# =============================================================================

echo "📋 Step 1: Create IAM Policy"
echo "============================"

POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
    echo "   Policy ARN: $POLICY_ARN"
else
    echo "🔄 Creating IAM policy..."
    
    # Download IAM policy from AWS documentation
    echo "📋 Downloading IAM policy from AWS documentation..."
    curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json
    
    # Create IAM policy
    echo "📋 Creating IAM policy..."
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json
    
    # Clean up
    rm -f iam_policy.json
    
    echo "✅ IAM policy created: $POLICY_ARN"
fi
echo ""

# =============================================================================
# STEP 2: CREATE IAM ROLE AND SERVICE ACCOUNT (MANUAL APPROACH)
# =============================================================================

echo "📋 Step 2: Create IAM Role and Service Account"
echo "=============================================="

# Get OIDC issuer URL
echo "🔍 Getting OIDC issuer URL for cluster..."
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo "$OIDC_ISSUER" | cut -d '/' -f 5)
echo "✅ OIDC Issuer: $OIDC_ISSUER"
echo "✅ OIDC ID: $OIDC_ID"
echo ""

# Check if OIDC provider exists
echo "🔍 Checking OIDC identity provider..."
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID" >/dev/null 2>&1; then
    echo "✅ OIDC provider already exists"
else
    echo "🔄 Creating OIDC identity provider..."
    
    # Get root CA thumbprint
    THUMBPRINT=$(echo | openssl s_client -servername oidc.eks.$AWS_REGION.amazonaws.com -connect oidc.eks.$AWS_REGION.amazonaws.com:443 2>/dev/null | openssl x509 -fingerprint -noout -sha1 | sed 's/://g' | awk -F= '{print tolower($2)}')
    
    aws iam create-open-id-connect-provider \
        --url "$OIDC_ISSUER" \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list "$THUMBPRINT"
    
    echo "✅ OIDC provider created"
fi
echo ""

# Create IAM role trust policy
echo "🔄 Creating IAM role trust policy..."
cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
                    "oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

# Create or update IAM role
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "✅ IAM role already exists: $ROLE_NAME"
    
    # Update trust policy
    echo "🔄 Updating trust policy..."
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document file://trust-policy.json
    echo "✅ Trust policy updated"
else
    echo "🔄 Creating IAM role..."
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json \
        --description "IAM role for AWS Load Balancer Controller"
    echo "✅ IAM role created: $ROLE_NAME"
fi

# Clean up trust policy file
rm -f trust-policy.json

# Attach policy to role
echo "🔄 Attaching policy to role..."
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN"
echo "✅ Policy attached to role"
echo ""

# Create Kubernetes service account
echo "🔄 Creating Kubernetes service account..."
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account already exists: $SERVICE_ACCOUNT_NAME"
else
    kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE"
    echo "✅ Service account created: $SERVICE_ACCOUNT_NAME"
fi

# Add IAM role annotation to service account
echo "🔄 Adding IAM role annotation to service account..."
kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" \
    eks.amazonaws.com/role-arn="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" \
    --overwrite
echo "✅ IAM role annotation added"
echo ""

# Verify service account configuration
echo "🔍 Verifying service account configuration..."
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account exists: $SERVICE_ACCOUNT_NAME"
    
    ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [[ -n "$ROLE_ARN" && "$ROLE_ARN" != "null" ]]; then
        echo "✅ IAM role annotation: $ROLE_ARN"
    else
        echo "❌ Service account missing IAM role annotation"
        exit 1
    fi
else
    echo "❌ Service account not found"
    exit 1
fi
echo ""

# =============================================================================
# STEP 3: INSTALL CERT-MANAGER (REQUIRED)
# =============================================================================

echo "📋 Step 3: Install cert-manager (Required)"
echo "=========================================="

if kubectl get namespace cert-manager >/dev/null 2>&1; then
    echo "✅ cert-manager namespace already exists"
else
    echo "🔄 Installing cert-manager..."
    kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.13.0/cert-manager.yaml
    
    echo "⏳ Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    
    echo "✅ cert-manager installed and ready"
fi
echo ""

# =============================================================================
# STEP 4: INSTALL AWS LOAD BALANCER CONTROLLER
# =============================================================================

echo "📋 Step 4: Install AWS Load Balancer Controller"
echo "=============================================="

# Add Helm repository
echo "🔄 Adding EKS Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
echo "✅ Helm repository configured"
echo ""

# Install AWS Load Balancer Controller
echo "🔄 Installing AWS Load Balancer Controller..."

# Check if already installed
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller"; then
    RELEASE_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    echo "ℹ️  Helm release exists with status: $RELEASE_STATUS"
    
    if [[ "$RELEASE_STATUS" != "deployed" ]]; then
        echo "⚠️  Removing failed release..."
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE"
        sleep 5
    fi
fi

# Install using Helm
if ! (helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller" && \
      helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' | grep -q "deployed"); then
    
    echo "📋 Installing with Helm..."
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n "$LB_NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --set vpcId="$VPC_ID" \
        --version="$HELM_CHART_VERSION"
    
    echo "✅ Helm installation completed"
else
    echo "📋 Upgrading existing deployment with VPC ID..."
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n "$LB_NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --set vpcId="$VPC_ID" \
        --version="$HELM_CHART_VERSION"
    
    echo "✅ Helm upgrade completed"
fi
echo ""

# =============================================================================
# STEP 5: VERIFY INSTALLATION
# =============================================================================

echo "📋 Step 5: Verify Installation"
echo "=============================="

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

# Wait for pods to be ready
echo "⏳ Waiting for pods to be ready..."
for i in {1..60}; do
    READY_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
    
    # Clean up variables to avoid octal interpretation
    READY_PODS=$(echo "$READY_PODS" | sed 's/^0*//' | grep -E '^[0-9]+$' || echo "0")
    TOTAL_PODS=$(echo "$TOTAL_PODS" | sed 's/^0*//' | grep -E '^[0-9]+$' || echo "0")
    
    echo "   Pod status: $READY_PODS/$TOTAL_PODS ready (attempt $i/60)"
    
    if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
        echo "✅ All pods are ready!"
        break
    fi
    
    sleep 5
done

# Final verification
echo ""
echo "🔍 Final Verification:"
echo "====================="

echo "📋 Deployment Status:"
kubectl get deployment -n "$LB_NAMESPACE" aws-load-balancer-controller
echo ""

echo "📋 Pod Status:"
kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
echo ""

# Final status check
FINAL_READY=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
FINAL_TOTAL=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")

# Clean up variables to avoid octal interpretation
FINAL_READY=$(echo "$FINAL_READY" | sed 's/^0*//' | grep -E '^[0-9]+$' || echo "0")
FINAL_TOTAL=$(echo "$FINAL_TOTAL" | sed 's/^0*//' | grep -E '^[0-9]+$' || echo "0")

if [ "$FINAL_READY" -gt 0 ] && [ "$FINAL_READY" -eq "$FINAL_TOTAL" ]; then
    echo "🎉 SUCCESS: AWS Load Balancer Controller is ready!"
    echo "✅ $FINAL_READY/$FINAL_TOTAL pods ready and running"
    echo "✅ Controller can now provision ALBs and NLBs"
    echo ""
    echo "✅ Installation completed successfully!"
    echo "📅 Completed at: $(date)"
    exit 0
else
    echo "❌ FAILED: AWS Load Balancer Controller is not ready"
    echo "   $FINAL_READY/$FINAL_TOTAL pods ready"
    echo ""
    echo "🔍 Troubleshooting:"
    kubectl describe deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
    echo ""
    kubectl describe pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    echo ""
    echo "❌ Installation failed!"
    exit 1
fi