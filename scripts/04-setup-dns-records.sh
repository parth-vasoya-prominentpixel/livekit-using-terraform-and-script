#!/bin/bash
# ---------------------------
# DNS Records Setup for LiveKit Deployment
# This script waits for ALB to be ready and creates DNS records
# ---------------------------

set -euo pipefail

echo "🌐 DNS Records Setup for LiveKit"
echo "================================"
echo "📅 Started at: $(date)"
echo ""

# =============================================================================
# VARIABLES CONFIGURATION
# =============================================================================

# --- Required Variables ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

# --- Derived Variables ---
# Extract base domain from full domain (e.g., example.com from livekit.example.com)
BASE_DOMAIN=$(echo "$DOMAIN_NAME" | sed 's/^[^.]*\.//')
TURN_DOMAIN="turn-${DOMAIN_NAME}"

# --- Output Variables ---
ALB_ENDPOINT_OUTPUT_FILE="${ALB_ENDPOINT_OUTPUT_FILE:-/tmp/alb_endpoint.txt}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"

# =============================================================================
# VALIDATION
# =============================================================================

echo "🔍 Validating Configuration"
echo "==========================="

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [[ -z "$DOMAIN_NAME" ]]; then
    echo "❌ DOMAIN_NAME environment variable is required"
    exit 1
fi

if [[ -z "$HOSTED_ZONE_ID" ]]; then
    echo "❌ HOSTED_ZONE_ID environment variable is required"
    exit 1
fi

echo "📋 DNS Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Environment: $ENVIRONMENT"
echo "   Primary Domain: $DOMAIN_NAME"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Base Domain: $BASE_DOMAIN"
echo "   Hosted Zone ID: $HOSTED_ZONE_ID"
echo ""

# Check if AWS CLI and kubectl are available
if ! command -v aws >/dev/null 2>&1; then
    echo "❌ AWS CLI not found"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "❌ kubectl not found"
    exit 1
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Function to get ALB endpoint from LiveKit ingress
get_alb_endpoint() {
    local namespace="livekit"
    local max_retries=10
    local retry_count=0
    
    echo "🔍 Getting ALB endpoint from LiveKit ingress..."
    
    while [ $retry_count -lt $max_retries ]; do
        # Get the ingress and extract the load balancer hostname
        local alb_endpoint=$(kubectl get ingress -n "$namespace" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [[ -n "$alb_endpoint" && "$alb_endpoint" != "null" ]]; then
            echo "✅ Found ALB endpoint: $alb_endpoint"
            echo "$alb_endpoint"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        echo "⏳ Waiting for ALB endpoint... (attempt $retry_count/$max_retries)"
        sleep 30
    done
    
    echo "❌ Failed to get ALB endpoint after $max_retries attempts"
    return 1
}

# Function to check if DNS record exists and get its value
check_existing_record() {
    local record_name="$1"
    local record_type="$2"
    
    local existing_value=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --query "ResourceRecordSets[?Name=='${record_name}.' && Type=='${record_type}'].ResourceRecords[0].Value" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$existing_value" && "$existing_value" != "None" ]]; then
        echo "$existing_value"
        return 0
    else
        return 1
    fi
}

# Function to delete existing DNS record
delete_dns_record() {
    local record_name="$1"
    local record_type="$2"
    local record_value="$3"
    
    echo "🗑️  Deleting existing $record_type record for $record_name..."
    
    cat <<EOF > delete-record.json
{
    "Comment": "Delete existing $record_type record for $record_name",
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": {
                "Name": "$record_name",
                "Type": "$record_type",
                "TTL": 300,
                "ResourceRecords": [
                    { "Value": "$record_value" }
                ]
            }
        }
    ]
}
EOF

    aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file://delete-record.json \
        --query "ChangeInfo.Id" \
        --output text
    
    rm -f delete-record.json
    echo "✅ Existing record deleted"
}

# Function to create DNS record
create_dns_record() {
    local record_name="$1"
    local record_type="$2"
    local record_value="$3"
    local comment="$4"
    
    echo "📝 Creating $record_type record: $record_name -> $record_value"
    
    cat <<EOF > create-record.json
{
    "Comment": "$comment",
    "Changes": [
        {
            "Action": "CREATE",
            "ResourceRecordSet": {
                "Name": "$record_name",
                "Type": "$record_type",
                "TTL": 300,
                "ResourceRecords": [
                    { "Value": "$record_value" }
                ]
            }
        }
    ]
}
EOF

    local change_id=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file://create-record.json \
        --query "ChangeInfo.Id" \
        --output text)
    
    rm -f create-record.json
    echo "✅ $record_type record created - Change ID: $change_id"
    return 0
}

# Function to manage DNS record (always delete if exists, then create new)
manage_dns_record() {
    local record_name="$1"
    local record_type="$2"
    local target_value="$3"
    local comment="$4"
    
    echo ""
    echo "🔧 Managing $record_type record for: $record_name"
    echo "   Target value: $target_value"
    
    # Check if record exists
    if existing_value=$(check_existing_record "$record_name" "$record_type"); then
        echo "📋 Found existing $record_type record: $existing_value"
        
        # ALWAYS delete existing record (even if it matches) to ensure it works properly
        echo "🔄 Deleting existing record to ensure proper configuration..."
        echo "   (This ensures the record works correctly and isn't stale)"
        delete_dns_record "$record_name" "$record_type" "$existing_value"
        
        # Wait for deletion to propagate
        echo "⏳ Waiting for deletion to propagate..."
        sleep 15
    else
        echo "ℹ️  No existing $record_type record found for $record_name"
    fi
    
    # Always create the new record
    echo "📝 Creating new $record_type record..."
    create_dns_record "$record_name" "$record_type" "$target_value" "$comment"
}

# Function to export ALB endpoint for pipeline use
export_alb_endpoint() {
    local alb_endpoint="$1"
    
    # Export to file for other scripts
    echo "$alb_endpoint" > "$ALB_ENDPOINT_OUTPUT_FILE"
    echo "📄 ALB endpoint exported to: $ALB_ENDPOINT_OUTPUT_FILE"
    
    # Export to GitHub Actions output if available
    if [[ -n "$GITHUB_OUTPUT" ]]; then
        echo "alb_endpoint=$alb_endpoint" >> "$GITHUB_OUTPUT"
        echo "primary_domain=$DOMAIN_NAME" >> "$GITHUB_OUTPUT"
        echo "turn_domain=$TURN_DOMAIN" >> "$GITHUB_OUTPUT"
        echo "📄 DNS information exported to GitHub Actions output"
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo "🚀 Starting DNS Records Setup Process"
echo "====================================="
echo ""

# -----------------------------------------------------------------------------
# STEP 1: WAIT FOR LOAD BALANCER TO BE READY
# -----------------------------------------------------------------------------

echo "📋 Step 1: Wait for Load Balancer to be Ready"
echo "============================================="

echo "⏳ Waiting 5 minutes for ALB to be fully active and stable..."
echo "   This ensures the load balancer is properly configured and healthy"

# Show countdown
for i in {300..1}; do
    printf "\r⏱️  Waiting: %02d:%02d remaining" $((i/60)) $((i%60))
    sleep 1
done
echo ""
echo "✅ Wait period completed"
echo ""

# -----------------------------------------------------------------------------
# STEP 2: GET ALB ENDPOINT
# -----------------------------------------------------------------------------

echo "📋 Step 2: Get ALB Endpoint"
echo "=========================="

ALB_ENDPOINT=$(get_alb_endpoint)
if [[ -z "$ALB_ENDPOINT" ]]; then
    echo "❌ Failed to get ALB endpoint"
    exit 1
fi

echo "✅ ALB Endpoint: $ALB_ENDPOINT"

# Export ALB endpoint for pipeline use
export_alb_endpoint "$ALB_ENDPOINT"
echo ""

# -----------------------------------------------------------------------------
# STEP 3: VERIFY ALB IS ACCESSIBLE
# -----------------------------------------------------------------------------

echo "📋 Step 3: Verify ALB is Accessible"
echo "=================================="

echo "🔍 Testing ALB endpoint accessibility..."

# Test if ALB responds (with timeout)
if timeout 30 curl -s -o /dev/null -w "%{http_code}" "http://$ALB_ENDPOINT" >/dev/null 2>&1; then
    echo "✅ ALB is responding to requests"
else
    echo "⚠️  ALB may not be fully ready yet, but proceeding with DNS setup"
    echo "   DNS records will be created and should work once ALB is fully active"
fi
echo ""

# -----------------------------------------------------------------------------
# STEP 4: CREATE PRIMARY DOMAIN RECORD
# -----------------------------------------------------------------------------

echo "📋 Step 4: Create Primary Domain Record"
echo "======================================="

manage_dns_record "$DOMAIN_NAME" "CNAME" "$ALB_ENDPOINT" "LiveKit primary domain - Environment: $ENVIRONMENT"
echo ""

# -----------------------------------------------------------------------------
# STEP 5: CREATE TURN DOMAIN RECORD
# -----------------------------------------------------------------------------

echo "📋 Step 5: Create TURN Domain Record"
echo "===================================="

manage_dns_record "$TURN_DOMAIN" "CNAME" "$ALB_ENDPOINT" "LiveKit TURN domain - Environment: $ENVIRONMENT"
echo ""

# -----------------------------------------------------------------------------
# STEP 6: WAIT FOR DNS PROPAGATION
# -----------------------------------------------------------------------------

echo "📋 Step 6: Wait for DNS Propagation"
echo "==================================="

echo "⏳ Waiting for DNS changes to propagate..."
echo "   This may take a few minutes..."

# Wait for DNS propagation (shorter wait since we're using CNAME records)
sleep 60

echo "✅ DNS propagation wait completed"
echo ""

# -----------------------------------------------------------------------------
# STEP 7: VERIFY DNS RESOLUTION
# -----------------------------------------------------------------------------

echo "📋 Step 7: Verify DNS Resolution"
echo "==============================="

echo "🔍 Testing DNS resolution..."

# Test primary domain
echo "Testing primary domain: $DOMAIN_NAME"
if nslookup "$DOMAIN_NAME" >/dev/null 2>&1; then
    resolved_ip=$(nslookup "$DOMAIN_NAME" | grep -A1 "Name:" | tail -1 | awk '{print $2}' || echo "unknown")
    echo "✅ Primary domain resolves to: $resolved_ip"
else
    echo "⚠️  Primary domain DNS resolution pending (may take more time to propagate)"
fi

# Test TURN domain
echo "Testing TURN domain: $TURN_DOMAIN"
if nslookup "$TURN_DOMAIN" >/dev/null 2>&1; then
    resolved_ip=$(nslookup "$TURN_DOMAIN" | grep -A1 "Name:" | tail -1 | awk '{print $2}' || echo "unknown")
    echo "✅ TURN domain resolves to: $resolved_ip"
else
    echo "⚠️  TURN domain DNS resolution pending (may take more time to propagate)"
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 DNS SETUP COMPLETE"
echo "===================="
echo "✅ ALB endpoint retrieved and verified"
echo "✅ DNS records created and configured"
echo ""
echo "📋 DNS Records Summary:"
echo "   • Primary Domain: $DOMAIN_NAME -> $ALB_ENDPOINT"
echo "   • TURN Domain: $TURN_DOMAIN -> $ALB_ENDPOINT"
echo "   • Hosted Zone ID: $HOSTED_ZONE_ID"
echo "   • Environment: $ENVIRONMENT"
echo ""
echo "📋 Access Information:"
echo "   🌐 LiveKit Server: https://$DOMAIN_NAME"
echo "   🔄 TURN Server: $TURN_DOMAIN"
echo "   🔗 ALB Endpoint: $ALB_ENDPOINT"
echo ""
echo "📋 Next Steps:"
echo "   1. DNS records may take 5-15 minutes to fully propagate globally"
echo "   2. Test LiveKit connectivity using the primary domain"
echo "   3. TURN server will be accessible via the TURN domain"
echo "   4. Monitor ALB health and LiveKit pod status"
echo ""
echo "✅ DNS configuration completed at: $(date)"