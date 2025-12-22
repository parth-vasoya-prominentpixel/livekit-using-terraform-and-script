#!/bin/bash

# LiveKit Deployment Script
# Creates configuration dynamically with proper Redis connectivity
# Reference: https://docs.livekit.io/deploy/kubernetes/

set -e

echo "🎥 LiveKit Deployment"
echo "===================="
echo "📋 Deploys LiveKit with ALB and proper Redis connectivity"

# Check required environment variables
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export REDIS_ENDPOINT=your-redis-endpoint"
    echo "  export AWS_REGION=us-east-1  # optional"
    echo "  ./03-deploy-livekit.sh"
    echo ""
    exit 1
fi

if [ -z "$REDIS_ENDPOINT" ]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export REDIS_ENDPOINT=your-redis-endpoint"
    echo "  export AWS_REGION=us-east-1  # optional"
    echo "  ./03-deploy-livekit.sh"
    echo ""
    exit 1
fi

# Set configuration
AWS_REGION=${AWS_REGION:-us-east-1}
NAMESPACE="livekit"
RELEASE_NAME="livekit"
DOMAIN="livekit-eks-tf.digi-telephony.com"
TURN_DOMAIN="turn-eks-tf.digi-telephony.com"

echo ""
echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"
echo "   Domain: $DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"

# Quick verification
echo ""
echo "🔍 Quick verification..."

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured"
    exit 1
fi

# Check cluster exists
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "❌ Cluster not found or not accessible"
    exit 1
fi

echo "✅ AWS and cluster verified"

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

# Verify Load Balancer Controller
echo ""
echo "🔍 Verifying AWS Load Balancer Controller..."
LB_CONTROLLERS=$(kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)

if [ "$LB_CONTROLLERS" -eq 0 ]; then
    echo "❌ No AWS Load Balancer Controller found"
    echo "� Please r un: ./scripts/02-setup-load-balancer.sh"
    exit 1
fi

echo "✅ Load Balancer Controller is ready"

# Create or use existing namespace
echo ""
echo "📦 Setting up namespace..."
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$NAMESPACE' exists"
    
    # Check for existing deployment
    if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit >/dev/null 2>&1; then
        echo "✅ Existing LiveKit deployment found - will upgrade"
        UPGRADE_EXISTING=true
    else
        echo "✅ Namespace ready for new deployment"
        UPGRADE_EXISTING=false
    fi
else
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
    UPGRADE_EXISTING=false
fi

# Setup Helm repository - Official LiveKit Charts
echo ""
echo "📦 Setting up LiveKit Helm repository..."
helm repo remove livekit >/dev/null 2>&1 || true
helm repo add livekit https://livekit.github.io/charts
helm repo update

echo "✅ Official LiveKit Helm repository ready"

# Get cluster information
echo ""
echo "🔍 Getting cluster information..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNET_IDS"

# Check certificate - Enhanced detection with fallback
echo ""
echo "🔍 Checking SSL certificate..."
CERT_ARN=""

# Step 1: Try to find certificate for the specific domain
echo "🔍 Looking for certificate for domain: $DOMAIN"
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text 2>/dev/null | head -1 || echo "")

# Step 2: If not found, try wildcard certificate for digi-telephony.com
if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" = "None" ]; then
    echo "🔍 Looking for wildcard certificate: *.digi-telephony.com"
    CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?DomainName=='*.digi-telephony.com'].CertificateArn" --output text 2>/dev/null | head -1 || echo "")
fi

# Step 3: If still not found, search by subject alternative names
if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" = "None" ]; then
    echo "🔍 Searching certificates by subject alternative names..."
    # Get all certificates and check their details
    ALL_CERTS=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[].CertificateArn" --output text 2>/dev/null || echo "")
    
    for cert in $ALL_CERTS; do
        if [ -n "$cert" ] && [ "$cert" != "None" ]; then
            # Check if this certificate covers our domain
            CERT_DOMAINS=$(aws acm describe-certificate --certificate-arn "$cert" --region "$AWS_REGION" --query "Certificate.SubjectAlternativeNames[]" --output text 2>/dev/null || echo "")
            
            # Check if our domain matches any of the certificate domains
            for cert_domain in $CERT_DOMAINS; do
                if [ "$cert_domain" = "$DOMAIN" ] || [ "$cert_domain" = "*.digi-telephony.com" ]; then
                    CERT_ARN="$cert"
                    echo "✅ Found matching certificate via SAN: $cert_domain"
                    break 2
                fi
            done
        fi
    done
fi

# Step 4: If still not found, use the existing fallback certificate
if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" = "None" ]; then
    CERT_ARN="arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414"
    echo "⚠️ No matching certificate found - using existing fallback certificate"
    echo "💡 Make sure this certificate covers domain: $DOMAIN"
else
    echo "✅ Found certificate: $(basename "$CERT_ARN")"
fi

echo "📋 Certificate ARN: $CERT_ARN"

# Verify certificate status
echo "🔍 Verifying certificate status..."
CERT_STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$AWS_REGION" --query "Certificate.Status" --output text 2>/dev/null || echo "UNKNOWN")
if [ "$CERT_STATUS" = "ISSUED" ]; then
    echo "✅ Certificate status: $CERT_STATUS"
else
    echo "⚠️ Certificate status: $CERT_STATUS (may cause issues)"
fi

# Create LiveKit configuration
echo ""
echo "🔧 Creating LiveKit configuration..."
cd "$(dirname "$0")/.."

cat > "livekit-values-deployment.yaml" << EOF
# LiveKit Configuration - ALB Only
# Domain: $DOMAIN

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
  metrics:
    enabled: true
    prometheus:
      enabled: true
      port: 6789
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - livekit-livekit-server
          topologyKey: "kubernetes.io/hostname"

turn:
  enabled: true
  domain: "$TURN_DOMAIN"
  tls_port: 3478
  udp_port: 3478

loadBalancer:
  type: alb
  tls:
    - hosts:
        - "$DOMAIN"
      certificateArn: "$CERT_ARN"

EOF

echo "✅ LiveKit configuration created"

# Deploy or upgrade LiveKit
CHART_VERSION="1.9.0"  # Latest stable version

if [ "$UPGRADE_EXISTING" = true ]; then
    echo ""
    echo "🔄 Upgrading existing LiveKit deployment..."
    HELM_ACTION="upgrade"
else
    echo ""
    echo "🚀 Installing new LiveKit deployment..."
    HELM_ACTION="install"
fi

echo "📋 Deployment details:"
echo "   Action: $HELM_ACTION"
echo "   Release: $RELEASE_NAME"
echo "   Chart: livekit/livekit"
echo "   Chart Version: $CHART_VERSION"
echo "   Namespace: $NAMESPACE"

echo ""
echo "⏳ Starting Helm $HELM_ACTION..."

# Attempt Helm deployment with better error handling
HELM_SUCCESS=false
MAX_HELM_ATTEMPTS=2

for attempt in $(seq 1 $MAX_HELM_ATTEMPTS); do
    echo "📋 Helm attempt $attempt/$MAX_HELM_ATTEMPTS..."
    
    if helm "$HELM_ACTION" "$RELEASE_NAME" livekit/livekit \
        -n "$NAMESPACE" \
        -f livekit-values-deployment.yaml \
        --version "$CHART_VERSION" \
        --wait --timeout=10m; then
        
        echo "✅ LiveKit $HELM_ACTION completed successfully!"
        HELM_SUCCESS=true
        break
    else
        echo "⚠️ Helm attempt $attempt failed"
        
        if [ $attempt -lt $MAX_HELM_ATTEMPTS ]; then
            echo "🔄 Retrying in 30 seconds..."
            sleep 30
        fi
    fi
done

if [ "$HELM_SUCCESS" = false ]; then
    echo "❌ LiveKit $HELM_ACTION failed after $MAX_HELM_ATTEMPTS attempts"
    
    echo ""
    echo "📋 Troubleshooting Information:"
    echo "🔍 Helm release status:"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
    
    echo ""
    echo "🔍 Pod status:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "   No pods found"
    
    echo ""
    echo "🔍 Recent pod events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 2>/dev/null || echo "   No events found"
    
    echo ""
    echo "💡 Common issues to check:"
    echo "   - Redis connectivity (security groups)"
    echo "   - Certificate ARN validity"
    echo "   - Load Balancer Controller status"
    echo "   - Resource limits and node capacity"
    
    exit 1
fi

# Wait for pods to be ready with better handling
echo ""
echo "⏳ Waiting for LiveKit pods to be ready..."

# Check if pods exist first
POD_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$POD_COUNT" -eq 0 ]; then
    echo "⚠️ No LiveKit pods found - checking deployment status..."
    kubectl get deployment -n "$NAMESPACE" 2>/dev/null || echo "   No deployments found"
    echo "💡 Pods may still be creating - continuing with deployment"
else
    echo "📋 Found $POD_COUNT LiveKit pod(s)"
    
    # Wait for pods with timeout
    if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1; then
        echo "✅ LiveKit pods are ready!"
    else
        echo "⚠️ Some pods may still be starting (timeout reached)"
        echo "📋 Current pod status:"
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit 2>/dev/null || echo "   No pods found"
        echo "💡 Deployment will continue - pods may become ready shortly"
    fi
fi

# Test Redis connectivity from LiveKit pods (non-blocking)
echo ""
echo "🔍 Testing Redis connectivity from LiveKit pods..."
LIVEKIT_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$LIVEKIT_POD" ]; then
    echo "📋 Testing from pod: $LIVEKIT_POD"
    
    # Test Redis connection (non-blocking - just informational)
    echo "🔍 Attempting Redis connectivity test..."
    
    # Try multiple methods to test Redis connectivity
    REDIS_TEST_RESULT="UNKNOWN"
    
    # Method 1: Try netcat if available
    if kubectl exec -n "$NAMESPACE" "$LIVEKIT_POD" -- which nc >/dev/null 2>&1; then
        if kubectl exec -n "$NAMESPACE" "$LIVEKIT_POD" -- timeout 5 nc -zv "${REDIS_ENDPOINT%:*}" "${REDIS_ENDPOINT##*:}" >/dev/null 2>&1; then
            REDIS_TEST_RESULT="SUCCESS"
        else
            REDIS_TEST_RESULT="FAILED_NC"
        fi
    # Method 2: Try telnet if netcat not available
    elif kubectl exec -n "$NAMESPACE" "$LIVEKIT_POD" -- which telnet >/dev/null 2>&1; then
        if kubectl exec -n "$NAMESPACE" "$LIVEKIT_POD" -- timeout 5 telnet "${REDIS_ENDPOINT%:*}" "${REDIS_ENDPOINT##*:}" >/dev/null 2>&1; then
            REDIS_TEST_RESULT="SUCCESS"
        else
            REDIS_TEST_RESULT="FAILED_TELNET"
        fi
    # Method 3: Try basic network test
    else
        echo "📋 Network tools not available in pod - skipping connectivity test"
        REDIS_TEST_RESULT="SKIPPED"
    fi
    
    # Report results (non-blocking)
    case "$REDIS_TEST_RESULT" in
        "SUCCESS")
            echo "✅ Redis connectivity test: SUCCESS"
            ;;
        "FAILED_NC"|"FAILED_TELNET")
            echo "⚠️ Redis connectivity test: FAILED (but this is non-blocking)"
            echo "💡 This may be normal - LiveKit will test Redis internally"
            echo "📋 Redis endpoint: $REDIS_ENDPOINT"
            echo "📋 Host: ${REDIS_ENDPOINT%:*}"
            echo "📋 Port: ${REDIS_ENDPOINT##*:}"
            echo "💡 Check LiveKit pod logs if Redis issues persist:"
            echo "   kubectl logs -n $NAMESPACE $LIVEKIT_POD"
            ;;
        "SKIPPED")
            echo "⚠️ Redis connectivity test: SKIPPED (no network tools available)"
            echo "💡 LiveKit will test Redis connectivity internally"
            ;;
        *)
            echo "⚠️ Redis connectivity test: UNKNOWN (but continuing deployment)"
            ;;
    esac
else
    echo "⚠️ No LiveKit pods found for connectivity test"
    echo "💡 This is normal if pods are still starting"
fi

echo ""
echo "💡 Note: Redis connectivity test is informational only"
echo "💡 LiveKit will establish Redis connection internally during startup"

# Show deployment status
echo ""
echo "📊 Deployment Status:"
RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l || echo "0")
echo "   Pods: $RUNNING_PODS/$TOTAL_PODS running"

# Check for ALB LoadBalancer endpoint with better handling
echo ""
echo "🌐 Checking ALB LoadBalancer endpoint..."

ALB_ADDRESS=""
ALB_FOUND=false

for i in {1..4}; do
    echo "📋 Attempt $i/4: Checking for ALB endpoint..."
    
    # Try to get the ALB address
    ALB_ADDRESS=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$ALB_ADDRESS" ] && [ "$ALB_ADDRESS" != "null" ]; then
        ALB_FOUND=true
        break
    fi
    
    if [ $i -lt 4 ]; then
        echo "   ALB still provisioning..."
        sleep 8
    fi
done

if [ "$ALB_FOUND" = true ]; then
    echo "✅ ALB Endpoint: https://$ALB_ADDRESS"
    echo "✅ LiveKit WebSocket: wss://$ALB_ADDRESS"
    echo ""
    echo "📋 DNS Configuration Required:"
    echo "   Create CNAME record: $DOMAIN → $ALB_ADDRESS"
    echo "   Create CNAME record: $TURN_DOMAIN → $ALB_ADDRESS"
else
    echo "⏳ ALB still provisioning (this is normal and may take 5-10 minutes)"
    echo ""
    echo "📋 Check ALB status later with:"
    echo "   kubectl get svc -n $NAMESPACE $RELEASE_NAME"
    echo "   kubectl describe svc -n $NAMESPACE $RELEASE_NAME"
    echo ""
    echo "💡 ALB provisioning continues in background"
fi

# Clean up temporary file
rm -f livekit-values-deployment.yaml

echo ""
echo "🎉 LiveKit Deployment Completed!"
echo "==============================="
echo ""
echo "📋 Summary:"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ Release: $RELEASE_NAME"
echo "   ✅ Chart Version: $CHART_VERSION"
echo "   ✅ Domain: $DOMAIN"
echo "   ✅ Redis: $REDIS_ENDPOINT"
echo ""
echo "📋 Next Steps:"
echo "   1. Wait for ALB to get endpoint (5-10 minutes)"
echo "   2. Update DNS to point $DOMAIN to ALB endpoint"
echo "   3. Test LiveKit connection"
echo ""
echo "📋 Monitoring Commands:"
echo "   - Check pods: kubectl get pods -n $NAMESPACE"
echo "   - Check services: kubectl get svc -n $NAMESPACE"
echo "   - Check ingress: kubectl get ingress -n $NAMESPACE"
echo "   - View logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit"
echo "   - Test Redis: kubectl exec -n $NAMESPACE <pod-name> -- nc -zv ${REDIS_ENDPOINT%:*} ${REDIS_ENDPOINT##*:}"
echo ""
echo "📋 Troubleshooting Commands:"
echo "   - Describe pods: kubectl describe pods -n $NAMESPACE"
echo "   - Check events: kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
echo "   - Helm status: helm status $RELEASE_NAME -n $NAMESPACE"
echo ""
echo "💡 Uses official LiveKit Helm repository: https://livekit.github.io/charts"
echo "💡 Uses correct chart: livekit/livekit (not livekit-server)"

# Final validation
echo ""
echo "🔍 Final Deployment Validation:"
echo "================================"

# Check namespace
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace: $NAMESPACE exists"
else
    echo "❌ Namespace: $NAMESPACE missing"
fi

# Check Helm release
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    HELM_STATUS=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    if [ "$HELM_STATUS" = "deployed" ]; then
        echo "✅ Helm Release: $RELEASE_NAME is deployed"
    else
        echo "⚠️ Helm Release: $RELEASE_NAME status is $HELM_STATUS"
    fi
else
    echo "❌ Helm Release: $RELEASE_NAME not found"
fi

# Check pods
RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$TOTAL_PODS" -gt 0 ]; then
    if [ "$RUNNING_PODS" -eq "$TOTAL_PODS" ]; then
        echo "✅ Pods: All $TOTAL_PODS pods are running"
    else
        echo "⚠️ Pods: $RUNNING_PODS/$TOTAL_PODS running"
    fi
else
    echo "❌ Pods: No LiveKit pods found"
fi

# Check service
if kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" >/dev/null 2>&1; then
    echo "✅ Service: $RELEASE_NAME exists"
else
    echo "❌ Service: $RELEASE_NAME missing"
fi

echo ""
if [ "$RUNNING_PODS" -gt 0 ] && helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "🎉 LiveKit deployment appears successful!"
    echo "💡 Monitor the ALB provisioning and update DNS records"
else
    echo "⚠️ LiveKit deployment may have issues - check the troubleshooting commands above"
fi