#!/bin/bash
# ---------------------------
# EKS Access Policy Configuration & ACM Certificate Automation
# This script configures EKS cluster access policies and sets up SSL certificates
# Includes smart certificate detection, CNAME management, and pipeline integration
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
ENVIRONMENT="${ENVIRONMENT:-dev}"

# --- ACM Certificate Variables ---
DOMAIN_NAME="${DOMAIN_NAME:-}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
CERT_REGION="${CERT_REGION:-$AWS_REGION}"  # use us-east-1 for CloudFront

# --- Output Variables for Pipeline Integration ---
CERT_ARN_OUTPUT_FILE="${CERT_ARN_OUTPUT_FILE:-/tmp/certificate_arn.txt}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"

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
echo "   Environment: $ENVIRONMENT"
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
# HELPER FUNCTIONS
# =============================================================================

# Function to check if certificate exists and is valid
check_existing_certificate() {
    local domain="$1"
    local region="$2"
    
    echo "🔍 Checking for existing certificate for domain: $domain"
    
    # List all certificates and filter by domain name
    local existing_cert=$(aws acm list-certificates \
        --region "$region" \
        --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$existing_cert" && "$existing_cert" != "None" ]]; then
        # Check certificate status
        local cert_status=$(aws acm describe-certificate \
            --certificate-arn "$existing_cert" \
            --region "$region" \
            --query "Certificate.Status" \
            --output text 2>/dev/null || echo "")
        
        if [[ "$cert_status" == "ISSUED" ]]; then
            echo "✅ Found existing ISSUED certificate: $existing_cert"
            return 0
        elif [[ "$cert_status" == "PENDING_VALIDATION" ]]; then
            echo "⏳ Found existing certificate pending validation: $existing_cert"
            echo "   Will continue with validation process..."
            return 1
        else
            echo "⚠️  Found existing certificate with status: $cert_status"
            echo "   Will request a new certificate..."
            return 1
        fi
    else
        echo "ℹ️  No existing certificate found for domain: $domain"
        return 1
    fi
}

# Function to export certificate ARN for pipeline use
export_certificate_arn() {
    local cert_arn="$1"
    
    # Export to file for other scripts
    echo "$cert_arn" > "$CERT_ARN_OUTPUT_FILE"
    echo "📄 Certificate ARN exported to: $CERT_ARN_OUTPUT_FILE"
    
    # Export to GitHub Actions output if available
    if [[ -n "$GITHUB_OUTPUT" ]]; then
        echo "certificate_arn=$cert_arn" >> "$GITHUB_OUTPUT"
        echo "📄 Certificate ARN exported to GitHub Actions output"
    fi
}

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
# STEP 6: CHECK FOR EXISTING CERTIFICATE
# -----------------------------------------------------------------------------

echo "📋 Step 6: Check for Existing Certificate"
echo "========================================="

CERT_ARN=""
CERT_EXISTS=false

if check_existing_certificate "$DOMAIN_NAME" "$CERT_REGION"; then
    # Get the existing certificate ARN
    CERT_ARN=$(aws acm list-certificates \
        --region "$CERT_REGION" \
        --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn" \
        --output text)
    
    CERT_EXISTS=true
    echo "✅ Using existing certificate: $CERT_ARN"
    
    # Export certificate ARN for pipeline use
    export_certificate_arn "$CERT_ARN"
    
    echo "ℹ️  Skipping certificate creation - using existing valid certificate"
    echo ""
else
    echo "🔄 Proceeding with new certificate request..."
    echo ""
fi

# -----------------------------------------------------------------------------
# STEP 7: REQUEST CERTIFICATE (if needed)
# -----------------------------------------------------------------------------

if [[ "$CERT_EXISTS" == "false" ]]; then
    echo "📋 Step 7: Request ACM Certificate"
    echo "=================================="

    echo "🔄 Requesting ACM certificate for domain: $DOMAIN_NAME"

    CERT_ARN=$(aws acm request-certificate \
        --domain-name "$DOMAIN_NAME" \
        --validation-method DNS \
        --region "$CERT_REGION" \
        --query CertificateArn \
        --output text)

    echo "✅ Certificate requested: $CERT_ARN"
    
    # Export certificate ARN for pipeline use
    export_certificate_arn "$CERT_ARN"
    echo ""

    # -----------------------------------------------------------------------------
    # STEP 8: WAIT FOR VALIDATION OPTIONS
    # -----------------------------------------------------------------------------

    echo "📋 Step 8: Wait for DNS Validation Records"
    echo "=========================================="

    echo "🔄 Waiting for DNS validation records to be available..."
    
    # Wait with retries for validation options to be available
    MAX_RETRIES=12
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        VALIDATION_OPTIONS=$(aws acm describe-certificate \
            --certificate-arn "$CERT_ARN" \
            --region "$CERT_REGION" \
            --query "Certificate.DomainValidationOptions[0].ResourceRecord" \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$VALIDATION_OPTIONS" && "$VALIDATION_OPTIONS" != "None" ]]; then
            echo "✅ DNS validation records are available"
            break
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "⏳ Waiting for validation records... (attempt $RETRY_COUNT/$MAX_RETRIES)"
        sleep 10
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "❌ Timeout waiting for DNS validation records"
        exit 1
    fi
    echo ""

    # -----------------------------------------------------------------------------
    # STEP 9: FETCH CNAME DETAILS
    # -----------------------------------------------------------------------------

    echo "📋 Step 9: Fetch CNAME Details"
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
    # STEP 10: CREATE ROUTE53 CNAME RECORD
    # -----------------------------------------------------------------------------

    echo "📋 Step 10: Create Route53 CNAME Record"
    echo "======================================="

    echo "🔄 Creating/updating Route53 CNAME record for DNS validation..."

    # Create change batch JSON file with UPSERT to handle existing records
    cat <<EOF > change-batch.json
{
    "Comment": "ACM DNS validation for $DOMAIN_NAME - Environment: $ENVIRONMENT",
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
    CHANGE_ID=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file://change-batch.json \
        --query "ChangeInfo.Id" \
        --output text)

    echo "✅ CNAME record created/updated in Route53"
    echo "📋 Change ID: $CHANGE_ID"
    echo ""

    # Clean up temporary file
    rm -f change-batch.json

    # -----------------------------------------------------------------------------
    # STEP 11: WAIT FOR DNS PROPAGATION
    # -----------------------------------------------------------------------------

    echo "📋 Step 11: Wait for DNS Propagation"
    echo "===================================="

    echo "🔄 Waiting for DNS changes to propagate..."
    
    # Wait for Route53 change to be propagated
    aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
    echo "✅ DNS changes propagated successfully"
    echo ""

    # -----------------------------------------------------------------------------
    # STEP 12: WAIT FOR CERTIFICATE ISSUANCE
    # -----------------------------------------------------------------------------

    echo "📋 Step 12: Wait for Certificate Issuance"
    echo "========================================="

    echo "🔄 Waiting for certificate to be ISSUED..."
    echo "   This may take several minutes..."

    # Wait for certificate with timeout
    timeout 600 aws acm wait certificate-issued \
        --certificate-arn "$CERT_ARN" \
        --region "$CERT_REGION" || {
        echo "⚠️  Certificate validation timeout - checking status..."
        
        CERT_STATUS=$(aws acm describe-certificate \
            --certificate-arn "$CERT_ARN" \
            --region "$CERT_REGION" \
            --query "Certificate.Status" \
            --output text)
        
        if [[ "$CERT_STATUS" == "ISSUED" ]]; then
            echo "✅ Certificate is now ISSUED!"
        else
            echo "❌ Certificate status: $CERT_STATUS"
            echo "   Please check AWS Console for more details"
            exit 1
        fi
    }

    echo "✅ Certificate ISSUED successfully!"
    echo ""
else
    echo "📋 Steps 7-12: Skipped (using existing certificate)"
    echo "=================================================="
    echo ""
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 SETUP COMPLETE"
echo "================="
echo "✅ EKS access policies configured for pipeline role"
echo "✅ ACM certificate ready for use"
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
echo "   • Environment: $ENVIRONMENT"
echo ""
echo "📋 Pipeline Integration:"
echo "   • Certificate ARN exported to: $CERT_ARN_OUTPUT_FILE"
if [[ -n "$GITHUB_OUTPUT" ]]; then
echo "   • Certificate ARN available in GitHub Actions output"
fi
echo ""
echo "📋 Next Steps:"
echo "   1. EKS policies may take a few minutes to propagate"
echo "   2. Pipeline can now proceed with Kubernetes operations"
echo "   3. SSL certificate is ready for use with Load Balancers/Ingress"
echo "   4. Load Balancer Controller setup can begin"
echo "   5. Certificate ARN can be used in subsequent pipeline steps"
echo ""
echo "✅ Configuration completed at: $(date)"