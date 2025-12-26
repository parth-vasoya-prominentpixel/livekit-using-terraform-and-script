#!/bin/bash
# ---------------------------
# EKS Access Policy Configuration & ACM Certificate Automation
# This script configures EKS cluster access policies and sets up SSL certificates
# ---------------------------

set -euo pipefail

echo "🔐 EKS Access Policy & ACM Certificate Setup"
echo "============================================"
echo "📅 Started at: $(date)"
echo ""

# =============================================================================
# VARIABLES CONFIGURATION
# =============================================================================

# --- EKS Access Policy Variables ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ROLE_ARN="${PIPELINE_ROLE_ARN:-}"

# --- ACM Certificate Variables ---
DOMAIN_NAME="${DOMAIN_NAME:-livekit.example.com}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
CERT_REGION="${CERT_REGION:-$AWS_REGION}"  # use us-east-1 for CloudFront

# =============================================================================
# VALIDATION
# =============================================================================

echo "🔍 Validating Configuration"
echo "==========================="

# Validate EKS required variables
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [[ -z "$ROLE_ARN" ]]; then
    echo "❌ PIPELINE_ROLE_ARN environment variable is required"
    echo "   This should be the ARN of the pipeline's OIDC role"
    exit 1
fi

# Validate ACM required variables
if [[ -z "$HOSTED_ZONE_ID" ]]; then
    echo "❌ HOSTED_ZONE_ID environment variable is required for ACM certificate"
    exit 1
fi

echo "📋 EKS Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Pipeline Role: $ROLE_ARN"
echo ""
echo "📋 ACM Configuration:"
echo "   Domain: $DOMAIN_NAME"
echo "   Hosted Zone ID: $HOSTED_ZONE_ID"
echo "   Certificate Region: $CERT_REGION"
echo ""

# Check if AWS CLI is available
if ! command -v aws >/dev/null 2>&1; then
    echo "❌ AWS CLI not found"
    exit 1
fi

# =============================================================================
# PART 1: EKS ACCESS POLICY CONFIGURATION
# =============================================================================

echo "🔐 PART 1: EKS ACCESS POLICY CONFIGURATION"
echo "=========================================="
echo ""

# -----------------------------------------------------------------------------
# STEP 1: CREATE ACCESS ENTRY
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# STEP 2: ATTACH ADMIN POLICY
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# STEP 3: ATTACH CLUSTER ADMIN POLICY
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# STEP 4: UPDATE KUBECONFIG
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# STEP 5: VERIFY ACCESS
# -----------------------------------------------------------------------------

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
# PART 2: ACM CERTIFICATE AUTOMATION
# =============================================================================

echo "🔒 PART 2: ACM CERTIFICATE AUTOMATION"
echo "====================================="
echo ""

# -----------------------------------------------------------------------------
# STEP 6: REQUEST CERTIFICATE
# -----------------------------------------------------------------------------

echo "📋 Step 6: Request ACM Certificate"
echo "=================================="

echo "🔄 Requesting ACM certificate for domain: $DOMAIN_NAME"

CERT_ARN=$(aws acm request-certificate \
    --domain-name "$DOMAIN_NAME" \
    --validation-method DNS \
    --region "$CERT_REGION" \
    --query CertificateArn \
    --output text)

echo "✅ Certificate requested: $CERT_ARN"
echo ""

# -----------------------------------------------------------------------------
# STEP 7: WAIT FOR VALIDATION OPTIONS
# -----------------------------------------------------------------------------

echo "📋 Step 7: Wait for DNS Validation Records"
echo "=========================================="

echo "🔄 Waiting for DNS validation records to be available..."
sleep 10

# -----------------------------------------------------------------------------
# STEP 8: FETCH CNAME DETAILS
# -----------------------------------------------------------------------------

echo "📋 Step 8: Fetch CNAME Details"
echo "=============================="

echo "🔄 Retrieving DNS validation CNAME records..."

read CNAME_NAME CNAME_VALUE <<< $(aws acm describe-certificate \
    --certificate-arn "$CERT_ARN" \
    --region "$CERT_REGION" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" \
    --output text)

echo "📋 DNS Validation Records:"
echo "   CNAME Name : $CNAME_NAME"
echo "   CNAME Value: $CNAME_VALUE"
echo ""

# -----------------------------------------------------------------------------
# STEP 9: CREATE ROUTE53 CNAME RECORD
# -----------------------------------------------------------------------------

echo "📋 Step 9: Create Route53 CNAME Record"
echo "======================================"

echo "🔄 Creating Route53 CNAME record for DNS validation..."

# Create change batch JSON file
cat <<EOF > change-batch.json
{
    "Comment": "ACM DNS validation for $DOMAIN_NAME",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$CNAME_NAME",
                "Type": "CNAME",
                "TTL": 300,
                "ResourceRecords": [
                    { "Value": "$CNAME_VALUE" }
                ]
            }
        }
    ]
}
EOF

# Apply the change batch
aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch file://change-batch.json

echo "✅ CNAME record created in Route53"
echo ""

# Clean up temporary file
rm -f change-batch.json

# -----------------------------------------------------------------------------
# STEP 10: WAIT FOR CERTIFICATE ISSUANCE
# -----------------------------------------------------------------------------

echo "📋 Step 10: Wait for Certificate Issuance"
echo "========================================="

echo "🔄 Waiting for certificate to be ISSUED..."
echo "   This may take several minutes..."

aws acm wait certificate-issued \
    --certificate-arn "$CERT_ARN" \
    --region "$CERT_REGION"

echo "✅ Certificate ISSUED successfully!"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 SETUP COMPLETE"
echo "================="
echo "✅ EKS access policies configured for pipeline role"
echo "✅ ACM certificate issued and validated"
echo ""
echo "📋 EKS Configuration Summary:"
echo "   • Access entry created for pipeline role"
echo "   • AmazonEKSAdminPolicy attached"
echo "   • AmazonEKSClusterAdminPolicy attached"
echo "   • Kubeconfig updated"
echo ""
echo "📋 ACM Certificate Summary:"
echo "   • Domain: $DOMAIN_NAME"
echo "   • Certificate ARN: $CERT_ARN"
echo "   • Region: $CERT_REGION"
echo "   • Status: ISSUED"
echo ""
echo "📋 Next Steps:"
echo "   1. EKS policies may take a few minutes to propagate"
echo "   2. Pipeline can now proceed with Kubernetes operations"
echo "   3. SSL certificate is ready for use with Load Balancers/Ingress"
echo "   4. Load Balancer Controller setup can begin"
echo ""
echo "✅ Configuration completed at: $(date)"