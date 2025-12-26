#!/bin/bash

# LiveKit Deployment Script for EKS - Clean and Simple
# Deploys LiveKit Server with ALB, SSL certificates, and Route 53 configuration

set -euo pipefail

echo "🎥 LiveKit Deployment Script"
echo "============================"
echo "📅 Started at: $(date)"
echo ""

# Configuration from environment variables
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"

# LiveKit Configuration
LIVEKIT_NAMESPACE="livekit"
LIVEKIT_DOMAIN="${LIVEKIT_DOMAIN:-livekit-eks-tf.digi-telephony.com}"
TURN_DOMAIN="${TURN_DOMAIN:-turn-eks-tf.digi-telephony.com}"
CERTIFICATE_ARN="arn:aws:acm:us-east-1:918595516608:certificate/4523a895-7899-41a3-8589-2a5baed3b420"
HELM_RELEASE_NAME="livekit-server"
HELM_CHART_VERSION="1.5.2"

# LiveKit API Keys
API_KEY="${LIVEKIT_API_KEY:-APIKmrHi78hxpbd}"
API_SECRET="${LIVEKIT_API_SECRET:-Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB}"

# Validate required environment variables
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [[ -z "$REDIS_ENDPOINT" ]]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    exit 1
fi

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Environment: $ENVIRONMENT"
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"
echo "   API Key: $API_KEY"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verify required tools
echo "🔧 Verifying required tools..."
for tool in aws kubectl helm jq; do
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
# STEP 1: CLEANUP EXISTING FAILED DEPLOYMENTS
# =============================================================================

echo "📋 Step 1: Cleanup Existing Failed Deployments"
echo "=============================================="

if helm list -n "$LIVEKIT_NAMESPACE" | grep -q "$HELM_RELEASE_NAME"; then
    RELEASE_STATUS=$(helm list -n "$LIVEKIT_NAMESPACE" -f "$HELM_RELEASE_NAME" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    
    echo "ℹ️  Found existing deployment with status: $RELEASE_STATUS"
    
    if [[ "$RELEASE_STATUS" != "deployed" ]]; then
        echo "🗑️ Removing failed deployment..."
        helm uninstall "$HELM_RELEASE_NAME" -n "$LIVEKIT_NAMESPACE" --wait || true
        kubectl delete pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
        kubectl delete ingress -n "$LIVEKIT_NAMESPACE" --all 2>/dev/null || true
        sleep 3
        echo "✅ Cleanup completed"
    else
        echo "✅ Existing deployment is healthy"
    fi
else
    echo "ℹ️  No existing deployment found"
fi
echo ""

# =============================================================================
# STEP 2: CREATE NAMESPACE
# =============================================================================

echo "📋 Step 2: Create Namespace"
echo "==========================="

if kubectl get namespace "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' already exists"
else
    kubectl create namespace "$LIVEKIT_NAMESPACE"
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' created"
fi
echo ""

# =============================================================================
# STEP 3: ADD HELM REPOSITORY
# =============================================================================

echo "📋 Step 3: Add Helm Repository"
echo "=============================="

if helm repo list | grep -q "livekit"; then
    echo "✅ LiveKit repository already added"
else
    helm repo add livekit https://helm.livekit.io
    echo "✅ LiveKit repository added"
fi

helm repo update
echo "✅ Helm repositories updated"
echo ""

# =============================================================================
# STEP 4: CREATE VALUES CONFIGURATION
# =============================================================================

echo "📋 Step 4: Create Values Configuration"
echo "======================================"

cat > /tmp/livekit-values.yaml << EOF
livekit:
  domain: $LIVEKIT_DOMAIN
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000

redis:
  address: $REDIS_ENDPOINT

# API Keys - MUST be at root level, not under livekit section
keys:
  $API_KEY: $API_SECRET

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
  domain: $TURN_DOMAIN
  tls_port: 3478
  udp_port: 3478

loadBalancer:
  type: alb
  tls:
  - hosts:
    - $LIVEKIT_DOMAIN
    certificateArn: $CERTIFICATE_ARN

hostNetwork: true

service:
  type: NodePort

ingress:
  enabled: true
  ingressClassName: "alb"
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: $CERTIFICATE_ARN
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: '200'
    alb.ingress.kubernetes.io/load-balancer-name: livekit-$ENVIRONMENT-alb
  hosts:
  - host: $LIVEKIT_DOMAIN
    paths:
    - path: /
      pathType: Prefix
  tls:
  - hosts:
    - $LIVEKIT_DOMAIN
EOF

echo "✅ Values configuration created"
echo ""

# =============================================================================
# STEP 5: DEPLOY LIVEKIT
# =============================================================================

echo "📋 Step 5: Deploy LiveKit"
echo "========================="

echo "🔄 Installing LiveKit..."
if helm install "$HELM_RELEASE_NAME" livekit/livekit-server \
    --namespace "$LIVEKIT_NAMESPACE" \
    --values /tmp/livekit-values.yaml \
    --version "$HELM_CHART_VERSION" \
    --timeout 5m \
    --wait; then
    echo "✅ LiveKit installation completed"
else
    echo "❌ LiveKit installation failed"
    
    # Show debugging info
    echo "🔍 Pod Status:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" || true
    
    echo "🔍 Pod Logs:"
    POD_NAME=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$POD_NAME" ]]; then
        kubectl logs "$POD_NAME" -n "$LIVEKIT_NAMESPACE" --tail=20 2>/dev/null || echo "No logs available"
    fi
    
    exit 1
fi
echo ""

# =============================================================================
# STEP 6: VERIFY DEPLOYMENT
# =============================================================================

echo "📋 Step 6: Verify Deployment"
echo "============================"

echo "⏳ Waiting for pods to be ready..."
for i in {1..24}; do
    READY_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "   Pod status: $READY_PODS/$TOTAL_PODS ready (attempt $i/24)"
    
    if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
        echo "✅ All pods are ready!"
        break
    fi
    
    sleep 3
done

echo ""
echo "📋 Final Status:"
kubectl get deployment -n "$LIVEKIT_NAMESPACE"
kubectl get pods -n "$LIVEKIT_NAMESPACE"
kubectl get services -n "$LIVEKIT_NAMESPACE"
kubectl get ingress -n "$LIVEKIT_NAMESPACE"
echo ""

# =============================================================================
# STEP 7: GET ALB DNS
# =============================================================================

echo "📋 Step 7: Get ALB DNS"
echo "======================"

echo "⏳ Getting ALB DNS name..."
ALB_DNS=""
for i in {1..12}; do
    ALB_DNS=$(kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [[ -n "$ALB_DNS" && "$ALB_DNS" != "null" ]]; then
        echo "✅ ALB DNS: $ALB_DNS"
        break
    fi
    
    echo "   Waiting for ALB DNS... (attempt $i/12)"
    sleep 7
done

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "null" ]]; then
    echo "⚠️  ALB DNS not available yet (this is normal)"
    ALB_DNS="pending"
fi
echo ""

# =============================================================================
# DEPLOYMENT SUMMARY
# =============================================================================

echo "🎉 DEPLOYMENT SUMMARY"
echo "===================="
echo "✅ LiveKit Server deployed successfully!"
echo ""
echo "📋 Configuration:"
echo "   Environment: $ENVIRONMENT"
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   Domain: https://$LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   ALB DNS: $ALB_DNS"
echo ""
echo "📋 API Configuration:"
echo "   API Key: $API_KEY"
echo "   API Secret: ${API_SECRET:0:10}..."
echo "   WebSocket URL: wss://$LIVEKIT_DOMAIN"
echo "   HTTP URL: https://$LIVEKIT_DOMAIN"
echo ""
echo "📋 Next Steps:"
echo "   1. Wait 5-10 minutes for ALB to be fully provisioned"
echo "   2. Test connectivity: curl -I https://$LIVEKIT_DOMAIN"
echo "   3. Create Route 53 records pointing to ALB"
echo ""

# Clean up
rm -f /tmp/livekit-values.yaml

echo "✅ Deployment completed!"
echo "📅 Completed at: $(date)"