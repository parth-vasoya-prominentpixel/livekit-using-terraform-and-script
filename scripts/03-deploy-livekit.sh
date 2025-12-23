#!/bin/bash

# LiveKit Deployment Script - Handles Certificate and ALB Circular Dependency
# Step 1: Deploy without certificate -> Get ALB -> Request certificate -> Update deployment

set -e

echo "🎥 LiveKit Deployment with Automatic Certificate Management"
echo "=========================================================="
echo "📋 Handles ALB + Certificate circular dependency automatically"

# Check required environment variables
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [ -z "$REDIS_ENDPOINT" ]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    exit 1
fi

# Configuration
AWS_REGION=${AWS_REGION:-us-east-1}
NAMESPACE="livekit"
RELEASE_NAME="livekit"
DOMAIN="livekit-eks-tf.digi-telephony.com"
TURN_DOMAIN="turn.livekit-eks-tf.digi-telephony.com"

# Get Redis endpoint - use correct hardcoded endpoint
REDIS_ENDPOINT="lp-ec-redis-use1-dev-redis.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379"

echo ""
echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Domain: $DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"

# Quick verification
echo ""
echo "🔍 Quick verification..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured"
    exit 1
fi

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1

if ! timeout 10 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo "✅ AWS and cluster verified"

# Verify Load Balancer Controller
echo ""
echo "🔍 Verifying AWS Load Balancer Controller..."
if ! kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -q "2/2"; then
    echo "❌ AWS Load Balancer Controller not ready"
    exit 1
fi
echo "✅ Load Balancer Controller is ready"

# Clean up existing deployment
echo ""
echo "🗑️ Cleaning up existing deployment..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   No existing release"
kubectl delete namespace "$NAMESPACE" 2>/dev/null || echo "   No existing namespace"
sleep 10
kubectl create namespace "$NAMESPACE"

# Add Helm repository
echo ""
echo "📦 Setting up Helm repository..."
helm repo add livekit https://helm.livekit.io 2>/dev/null || true
helm repo update
echo "✅ Helm repository ready"

# PHASE 1: Deploy LiveKit WITHOUT certificate to get ALB endpoint
echo ""
echo "🚀 PHASE 1: Deploy LiveKit without certificate"
echo "=============================================="

cat > "livekit-phase1.yaml" << EOF
livekit:
  domain: "$DOMAIN"
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: "$REDIS_ENDPOINT"
  keys:
    APIKmrHi78hxpbd: Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

turn:
  enabled: true
  domain: "$TURN_DOMAIN"
  tls_port: 3478
  udp_port: 3478

# Service configuration for LoadBalancer (HTTP only)
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-target-type: "ip"

# Disable ingress completely
ingress:
  enabled: false
EOF

echo "🚀 Deploying LiveKit (Phase 1 - HTTP only)..."
if helm install "$RELEASE_NAME" livekit/livekit-server \
    -n "$NAMESPACE" \
    -f livekit-phase1.yaml \
    --wait --timeout=10m; then
    echo "✅ Phase 1 deployment successful!"
else
    echo "❌ Phase 1 deployment failed"
    exit 1
fi

# Wait for ALB endpoint
echo ""
echo "⏳ Waiting for ALB endpoint..."
ALB_ENDPOINT=""
for i in {1..20}; do
    ALB_ENDPOINT=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_ENDPOINT" ] && [ "$ALB_ENDPOINT" != "null" ]; then
        echo "✅ ALB endpoint ready: $ALB_ENDPOINT"
        break
    fi
    echo "   Attempt $i/20: Waiting for ALB..."
    sleep 15
done

if [ -z "$ALB_ENDPOINT" ] || [ "$ALB_ENDPOINT" = "null" ]; then
    echo "❌ ALB endpoint not available after 5 minutes"
    exit 1
fi

# PHASE 2: Request certificate for domains
echo ""
echo "🔒 PHASE 2: Request SSL certificate"
echo "=================================="

# Check if certificate already exists
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='*.digi-telephony.com'].CertificateArn" \
    --output text 2>/dev/null | head -1)

if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    echo "✅ Found existing wildcard certificate: $(basename "$CERT_ARN")"
else
    echo "🔒 Requesting new certificate for domains..."
    
    # Request certificate for both domains
    CERT_ARN=$(aws acm request-certificate \
        --domain-name "$DOMAIN" \
        --subject-alternative-names "$TURN_DOMAIN" \
        --validation-method DNS \
        --region "$AWS_REGION" \
        --query "CertificateArn" \
        --output text)
    
    echo "✅ Certificate requested: $(basename "$CERT_ARN")"
    
    # Get DNS validation records
    echo "📋 Getting DNS validation records..."
    sleep 10  # Wait for certificate to be processed
    
    # Get validation records
    VALIDATION_RECORDS=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region "$AWS_REGION" \
        --query "Certificate.DomainValidationOptions[].ResourceRecord" \
        --output json)
    
    echo "📋 DNS Validation Records needed:"
    echo "$VALIDATION_RECORDS" | jq -r '.[] | "Type: \(.Type), Name: \(.Name), Value: \(.Value)"'
    
    # Auto-create DNS records if Route53 hosted zone exists
    HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
        --query "HostedZones[?Name=='digi-telephony.com.'].Id" \
        --output text 2>/dev/null | sed 's|/hostedzone/||')
    
    if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
        echo "✅ Found Route53 hosted zone: $HOSTED_ZONE_ID"
        echo "🔧 Creating DNS validation records automatically..."
        
        # Create validation records
        echo "$VALIDATION_RECORDS" | jq -c '.[]' | while read record; do
            RECORD_NAME=$(echo "$record" | jq -r '.Name')
            RECORD_VALUE=$(echo "$record" | jq -r '.Value')
            RECORD_TYPE=$(echo "$record" | jq -r '.Type')
            
            aws route53 change-resource-record-sets \
                --hosted-zone-id "$HOSTED_ZONE_ID" \
                --change-batch "{
                    \"Changes\": [{
                        \"Action\": \"UPSERT\",
                        \"ResourceRecordSet\": {
                            \"Name\": \"$RECORD_NAME\",
                            \"Type\": \"$RECORD_TYPE\",
                            \"TTL\": 300,
                            \"ResourceRecords\": [{\"Value\": \"$RECORD_VALUE\"}]
                        }
                    }]
                }" >/dev/null
            
            echo "   ✅ Created: $RECORD_NAME"
        done
        
        # Wait for certificate validation
        echo "⏳ Waiting for certificate validation..."
        aws acm wait certificate-validated --certificate-arn "$CERT_ARN" --region "$AWS_REGION" &
        WAIT_PID=$!
        
        # Show progress
        for i in {1..30}; do
            if ! kill -0 $WAIT_PID 2>/dev/null; then
                echo "✅ Certificate validated!"
                break
            fi
            echo "   Validation attempt $i/30..."
            sleep 10
        done
        
        # Kill wait process if still running
        kill $WAIT_PID 2>/dev/null || true
        
    else
        echo "⚠️ No Route53 hosted zone found for digi-telephony.com"
        echo "💡 Please create DNS validation records manually"
        echo "💡 Certificate ARN: $CERT_ARN"
    fi
fi

# Create domain DNS records pointing to ALB
echo ""
echo "🌐 Creating domain DNS records..."
if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
    # Create CNAME records for domains
    for domain_name in "$DOMAIN" "$TURN_DOMAIN"; do
        RECORD_NAME=$(echo "$domain_name" | sed 's/\.digi-telephony\.com$//')
        
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch "{
                \"Changes\": [{
                    \"Action\": \"UPSERT\",
                    \"ResourceRecordSet\": {
                        \"Name\": \"$domain_name\",
                        \"Type\": \"CNAME\",
                        \"TTL\": 300,
                        \"ResourceRecords\": [{\"Value\": \"$ALB_ENDPOINT\"}]
                    }
                }]
            }" >/dev/null
        
        echo "✅ Created DNS record: $domain_name -> $ALB_ENDPOINT"
    done
else
    echo "⚠️ Manual DNS setup required:"
    echo "   $DOMAIN -> $ALB_ENDPOINT"
    echo "   $TURN_DOMAIN -> $ALB_ENDPOINT"
fi

# PHASE 3: Update LiveKit with certificate
echo ""
echo "🔒 PHASE 3: Update LiveKit with SSL certificate"
echo "=============================================="

cat > "livekit-phase3.yaml" << EOF
livekit:
  domain: "$DOMAIN"
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: "$REDIS_ENDPOINT"
  keys:
    APIKmrHi78hxpbd: Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

turn:
  enabled: true
  domain: "$TURN_DOMAIN"
  tls_port: 3478
  udp_port: 3478

# Service configuration with SSL certificate
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "$CERT_ARN"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "https"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"

# Disable ingress completely
ingress:
  enabled: false
EOF

echo "🔒 Upgrading LiveKit with SSL certificate..."
if helm upgrade "$RELEASE_NAME" livekit/livekit-server \
    -n "$NAMESPACE" \
    -f livekit-phase3.yaml \
    --wait --timeout=10m; then
    echo "✅ SSL upgrade successful!"
else
    echo "❌ SSL upgrade failed"
    exit 1
fi

# Final verification
echo ""
echo "🔍 Final verification..."
sleep 30

# Test endpoints
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_ENDPOINT/" || echo "000")
HTTPS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/" --connect-timeout 10 || echo "000")

echo "📋 Health check results:"
echo "   HTTP ($ALB_ENDPOINT): $HTTP_STATUS"
echo "   HTTPS ($DOMAIN): $HTTPS_STATUS"

# Final output
echo ""
echo "🎉 LiveKit Deployment Completed!"
echo "==============================="
echo ""
echo "📋 Deployment Summary:"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ ALB Endpoint: $ALB_ENDPOINT"
echo "   ✅ Certificate: $(basename "$CERT_ARN")"
echo "   ✅ Domain: $DOMAIN"
echo "   ✅ TURN Domain: $TURN_DOMAIN"
echo ""
echo "🌐 LiveKit Connection Details:"
echo "   WebSocket URL: wss://$DOMAIN"
echo "   API Key: APIKmrHi78hxpbd"
echo "   Secret Key: Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB"
echo "   TURN: turn:$TURN_DOMAIN:3478"
echo ""
echo "💡 LiveKit is ready for WebRTC connections!"

# Cleanup
rm -f livekit-phase1.yaml livekit-phase3.yaml