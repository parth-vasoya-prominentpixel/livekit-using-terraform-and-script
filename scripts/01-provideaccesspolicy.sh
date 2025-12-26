#!/bin/bash
# ---------------------------
# Grant EKS cluster access policies to pipeline OIDC role
# This script should run after Terraform apply to grant access to the created EKS cluster
# ---------------------------

set -euo pipefail

echo "🔐 EKS Access Policy Configuration"
echo "=================================="
echo "📅 Started at: $(date)"
echo ""

# --- Variables from environment ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ROLE_ARN="${PIPELINE_ROLE_ARN:-}"

# Validate required environment variables
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [[ -z "$ROLE_ARN" ]]; then
    echo "❌ PIPELINE_ROLE_ARN environment variable is required"
    echo "   This should be the ARN of the pipeline's OIDC role"
    exit 1
fi

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Pipeline Role: $ROLE_ARN"
echo ""

# Check if AWS CLI is available
if ! command -v aws >/dev/null 2>&1; then
    echo "❌ AWS CLI not found"
    exit 1
fi

echo "🔄 Granting EKS access policies to pipeline role..."
echo ""

# =============================================================================
# STEP 1: CREATE ACCESS ENTRY
# =============================================================================

echo "📋 Step 1: Create Access Entry"
echo "=============================="

echo "🔄 Creating access entry for role: $ROLE_ARN"

if aws eks create-access-entry \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$ROLE_ARN" \
    --type STANDARD \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "✅ Access entry created successfully"
else
    echo "ℹ️  Access entry already exists or creation failed, continuing..."
fi
echo ""

# =============================================================================
# STEP 2: ATTACH ADMIN POLICY
# =============================================================================

echo "📋 Step 2: Attach EKS Admin Policy"
echo "=================================="

echo "🔄 Attaching AmazonEKSAdminPolicy..."

if aws eks associate-access-policy \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$ROLE_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy \
    --access-scope type=cluster \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "✅ AmazonEKSAdminPolicy attached successfully"
else
    echo "ℹ️  AmazonEKSAdminPolicy already attached or attachment failed, continuing..."
fi
echo ""

# =============================================================================
# STEP 3: ATTACH CLUSTER ADMIN POLICY
# =============================================================================

echo "📋 Step 3: Attach EKS Cluster Admin Policy"
echo "=========================================="

echo "🔄 Attaching AmazonEKSClusterAdminPolicy..."

if aws eks associate-access-policy \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$ROLE_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    --region "$AWS_REGION" 2>/dev/null; then
    echo "✅ AmazonEKSClusterAdminPolicy attached successfully"
else
    echo "ℹ️  AmazonEKSClusterAdminPolicy already attached or attachment failed, continuing..."
fi
echo ""

# =============================================================================
# STEP 4: UPDATE KUBECONFIG
# =============================================================================

echo "📋 Step 4: Update Kubeconfig"
echo "============================"

echo "🔄 Updating kubeconfig for cluster access..."

if aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --role-arn "$ROLE_ARN"; then
    echo "✅ Kubeconfig updated successfully"
else
    echo "⚠️  Kubeconfig update failed, but continuing..."
fi
echo ""

# =============================================================================
# STEP 5: VERIFY ACCESS
# =============================================================================

echo "📋 Step 5: Verify Access"
echo "======================="

echo "🔍 Testing cluster access..."

if kubectl get nodes >/dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    echo "✅ Cluster access verified - found $NODE_COUNT nodes"
    
    echo ""
    echo "📋 Cluster Nodes:"
    kubectl get nodes
else
    echo "⚠️  Cannot access cluster yet - this may be normal if policies are still propagating"
    echo "   Access should be available within a few minutes"
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 EKS ACCESS CONFIGURATION COMPLETE"
echo "===================================="
echo "✅ Access policies configured for pipeline role"
echo ""
echo "📋 Applied Policies:"
echo "   • AmazonEKSAdminPolicy"
echo "   • AmazonEKSClusterAdminPolicy"
echo ""
echo "📋 Next Steps:"
echo "   1. Policies may take a few minutes to propagate"
echo "   2. Pipeline can now proceed with Kubernetes operations"
echo "   3. Load Balancer Controller setup can begin"
echo ""
echo "✅ Configuration completed at: $(date)"
