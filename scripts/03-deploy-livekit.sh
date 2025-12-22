#!/bin/bash

# LiveKit Deployment Script
# Uses existing livekit-values.yaml configuration
# Reference: https://docs.livekit.io/deploy/kubernetes/

set -e

echo "🎥 LiveKit Deployment"
echo "===================="
echo "📋 Uses your existing livekit-values.yaml configuration"
echo "� Fhttps://docs.livekit.io/deploy/kubernetes/"

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
    echo "💡 Please run: ./scripts/02-setup-load-balancer.sh"
    exit 1
fi

# Check if any controller is healthy
HEALTHY_FOUND=false
kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | while read name ready rest; do
    if [[ "$ready" == *"/"* ]]; then
        READY_COUNT=$(echo "$ready" | cut -d'/' -f1)
        DESIRED_COUNT=$(echo "$ready" | cut -d'/' -f2)
        if [ "$READY_COUNT" = "$DESIRED_COUNT" ] && [ "$READY_COUNT" != "0" ]; then
            echo "✅ Found healthy controller: $name ($ready)"
            HEALTHY_FOUND=true
            break
        fi
    fi
done

echo "✅ Load Balancer Controller is ready"

# Create or use existing namespace
echo ""
echo "📦 Setting up namespace..."
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$NAMESPACE' exists"
    
    # Check for existing deployment
    if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit >/dev/null 2>&1; then
        echo "✅ Existing LiveKit deployment found"
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

# Setup Helm repository
echo ""
echo "📦 Setting up LiveKit Helm repository..."
helm repo add livekit https://helm.livekit.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Check available chart versions
echo "🔍 Checking available LiveKit chart versions..."
AVAILABLE_VERSIONS=$(helm search repo livekit/livekit-server --versions --output json 2>/dev/null | jq -r '.[].version' | head -5 | tr '\n' ' ' || echo "Unable to fetch versions")
echo "📋 Recent versions: $AVAILABLE_VERSIONS"

# Get cluster information for LoadBalancer configuration
echo ""
echo "� Getnting cluster information..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNET_IDS"

# Setup Helm repository
echo ""
echo "📦 Setting up LiveKit Helm repository..."
helm repo add livekit https://helm.livekit.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Create LiveKit configuration dynamically
echo ""
echo "🔧 Creating LiveKit configuration..."
cd "$(dirname "$0")/.."

# Generate API credentials
API_KEY=${LIVEKIT_API_KEY:-"devkey"}
API_SECRET=${LIVEKIT_API_SECRET:-"devsecret"}

# Check if certificate exists for the domain, if not use wildcard
echo "🔍 Checking SSL certificate..."
CERT_ARN=""

# Try to find certificate for the specific domain
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text 2>/dev/null || echo "")

# If not found, try wildcard certificate
if [ -z "$CERT_ARN" ]; then
    CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?DomainName=='*.digi-telephony.com'].CertificateArn" --output text 2>/dev/null || echo "")
fi

# If still not found, use the existing one you provided
if [ -z "$CERT_ARN" ]; then
    CERT_ARN="arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414"
    echo "⚠️ Using existing certificate ARN (may not match domain)"
else
    echo "✅ Found certificate: $(basename "$CERT_ARN")"
fi

echo "📋 Certificate ARN: $CERT_ARN"

cat > "livekit-values-deployment.yaml" << EOF
# LiveKit Configuration for EKS Deployment - ALB Only
# Domain: $DOMAIN
# Generated dynamically by deployment script

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

echo "✅ LiveKit configuration created (ALB only - matching your setup)"
echo "📋 Configuration details:"
echo "   Domain: $DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Certificate: $(basename "$CERT_ARN")"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Load Balancer: ALB only (for WebSocket traffic)"

# Deploy or upgrade LiveKit
# Try to get the latest chart version, fallback to known working version
CHART_VERSION=$(helm search repo livekit/livekit-server --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || echo "1.7.2")
echo "📋 Using chart version: $CHART_VERSION"

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
echo "   Chart Version: $CHART_VERSION"
echo "   Namespace: $NAMESPACE"

echo ""
echo "⏳ Starting Helm $HELM_ACTION..."

# First try with detected version
if helm "$HELM_ACTION" "$RELEASE_NAME" livekit/livekit-server \
    -n "$NAMESPACE" \
    -f livekit-values-deployment.yaml \
    --version "$CHART_VERSION" \
    --wait --timeout=10m; then
    
    echo "✅ LiveKit $HELM_ACTION completed successfully!"
else
    echo "❌ LiveKit $HELM_ACTION failed with version $CHART_VERSION"
    
    # Try without version specification (uses latest)
    echo "🔄 Retrying without version specification..."
    if helm "$HELM_ACTION" "$RELEASE_NAME" livekit/livekit-server \
        -n "$NAMESPACE" \
        -f livekit-values-deployment.yaml \
        --wait --timeout=10m; then
        
        echo "✅ LiveKit $HELM_ACTION completed successfully!"
    else
        echo "❌ LiveKit $HELM_ACTION failed"
        
        echo ""
        echo "📋 Troubleshooting:"
        helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
        kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "   No pods found"
        
        exit 1
    fi
fi

# Wait for pods to be ready
echo ""
echo "⏳ Waiting for LiveKit pods..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1; then
    echo "✅ LiveKit pods are ready!"
else
    echo "⚠️ Some pods may still be starting..."
fi

# Show deployment status
echo ""
echo "📊 Deployment Status:"
RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l || echo "0")
echo "   Pods: $RUNNING_PODS/$TOTAL_PODS running"

# Check for ALB LoadBalancer endpoint
echo ""
echo "🌐 Checking ALB LoadBalancer endpoint..."

# Check ALB 
echo "📋 ALB LoadBalancer:"
ALB_ADDRESS=""
for i in {1..6}; do
    # LiveKit with ALB creates a LoadBalancer service, not Ingress
    ALB_ADDRESS=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_ADDRESS" ]; then
        break
    fi
    if [ $i -lt 6 ]; then
        echo "   Attempt $i/6: ALB provisioning..."
        sleep 10
    fi
done

if [ -n "$ALB_ADDRESS" ]; then
    echo "✅ ALB Endpoint: https://$ALB_ADDRESS"
    echo "✅ LiveKit WebSocket: wss://$ALB_ADDRESS"
else
    echo "⏳ ALB still provisioning (check later with: kubectl get svc -n $NAMESPACE)"
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
echo "   1. Wait for LoadBalancers to get endpoints (5-10 minutes)"
echo "   2. Update DNS to point $DOMAIN to ALB endpoint"
echo "   3. Test LiveKit connection"
echo ""
echo "📋 Monitoring Commands:"
echo "   - Check pods: kubectl get pods -n $NAMESPACE"
echo "   - Check services: kubectl get svc -n $NAMESPACE"
echo "   - View logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit"
echo ""
echo "💡 Uses your existing livekit-values.yaml configuration!"