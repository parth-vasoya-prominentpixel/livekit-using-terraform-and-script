#!/bin/bash

# LiveKit Deployment Script for EKS
# Clean, simple deployment based on official LiveKit documentation
# https://docs.livekit.io/realtime/self-hosting/deployment/

set -euo pipefail

echo "🎥 LiveKit Server Deployment"
echo "============================"
echo "📅 Started at: $(date)"
echo ""

# =============================================================================
# CONFIGURATION
# =============================================================================

# Required environment variables
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"

# LiveKit configuration
LIVEKIT_NAMESPACE="livekit"
LIVEKIT_DOMAIN="livekit-eks-tf.digi-telephony.com"
CERTIFICATE_ARN="arn:aws:acm:us-east-1:918595516608:certificate/4523a895-7899-41a3-8589-2a5baed3b420"
HELM_RELEASE_NAME="livekit-server"
HELM_CHART_VERSION="1.5.2"

# Generate LiveKit API keys (standard format)
API_KEY="API$(openssl rand -hex 8)"
API_SECRET=$(openssl rand -base64 32)

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"
echo "   API Key: $API_KEY"
echo "   API Secret: ${API_SECRET:0:20}..."
echo ""

# Validate required variables
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [[ -z "$REDIS_ENDPOINT" ]]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    exit 1
fi

# =============================================================================
# PREREQUISITES
# =============================================================================

echo "🔧 Checking prerequisites..."

# Check required tools
for tool in aws kubectl helm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "❌ $tool is required but not installed"
        exit 1
    fi
    echo "✅ $tool: available"
done

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

# Verify cluster connectivity
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo "✅ Connected to cluster with $NODE_COUNT nodes"
echo ""

# =============================================================================
# CLEANUP EXISTING DEPLOYMENT
# =============================================================================

echo "🧹 Cleaning up existing deployment..."

# Remove existing Helm release if it exists
if helm list -n "$LIVEKIT_NAMESPACE" 2>/dev/null | grep -q "$HELM_RELEASE_NAME"; then
    echo "🗑️ Removing existing Helm release..."
    helm uninstall "$HELM_RELEASE_NAME" -n "$LIVEKIT_NAMESPACE" --timeout 60s || true
    sleep 10
fi

# Force cleanup any remaining resources
kubectl delete pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
kubectl delete ingress -n "$LIVEKIT_NAMESPACE" --all --timeout=30s 2>/dev/null || true

echo "✅ Cleanup completed"
echo ""

# =============================================================================
# NAMESPACE SETUP
# =============================================================================

echo "📦 Setting up namespace..."

if ! kubectl get namespace "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    kubectl create namespace "$LIVEKIT_NAMESPACE"
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' created"
else
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' already exists"
fi
echo ""

# =============================================================================
# HELM REPOSITORY
# =============================================================================

echo "📚 Setting up Helm repository..."

if ! helm repo list 2>/dev/null | grep -q "livekit"; then
    helm repo add livekit https://helm.livekit.io
    echo "✅ LiveKit repository added"
else
    echo "✅ LiveKit repository already exists"
fi

helm repo update
echo "✅ Helm repositories updated"
echo ""

# =============================================================================
# VALUES CONFIGURATION
# =============================================================================

echo "⚙️ Creating Helm values configuration..."

cat > /tmp/livekit-values.yaml << EOF
# LiveKit Server Configuration
# Based on official documentation: https://docs.livekit.io/realtime/self-hosting/deployment/

# Core LiveKit configuration
livekit:
  # Domain for LiveKit server
  domain: $LIVEKIT_DOMAIN
  
  # RTC configuration for WebRTC
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
    
  # Logging configuration
  log_level: info

# Redis configuration for state management
redis:
  address: $REDIS_ENDPOINT

# API Keys for authentication
keys:
  "$API_KEY": "$API_SECRET"

# Resource limits
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 4Gi

# Service configuration
service:
  type: ClusterIP
  annotations: {}

# Ingress configuration for ALB
ingress:
  enabled: true
  className: "alb"
  annotations:
    # ALB configuration
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: $CERTIFICATE_ARN
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: '200'
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '30'
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '5'
    alb.ingress.kubernetes.io/healthy-threshold-count: '2'
    alb.ingress.kubernetes.io/unhealthy-threshold-count: '3'
  hosts:
    - host: $LIVEKIT_DOMAIN
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - $LIVEKIT_DOMAIN

# Metrics and monitoring
metrics:
  enabled: true
  prometheus:
    enabled: true
    port: 6789

# Pod configuration
replicaCount: 1

# Security context
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000

# Node selection
nodeSelector: {}
tolerations: []
affinity: {}

# Liveness and readiness probes
livenessProbe:
  httpGet:
    path: /
    port: 7880
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /
    port: 7880
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
EOF

echo "✅ Values configuration created"
echo ""

# Show the configuration for debugging
echo "🔍 Generated configuration:"
echo "=========================="
cat /tmp/livekit-values.yaml
echo "=========================="
echo ""

# =============================================================================
# DEPLOYMENT
# =============================================================================

echo "🚀 Deploying LiveKit Server..."
echo "   📦 Chart version: $HELM_CHART_VERSION"
echo "   🎯 Namespace: $LIVEKIT_NAMESPACE"
echo "   ⏱️ Timeout: 10 minutes"
echo ""

if helm install "$HELM_RELEASE_NAME" livekit/livekit-server \
    --namespace "$LIVEKIT_NAMESPACE" \
    --values /tmp/livekit-values.yaml \
    --version "$HELM_CHART_VERSION" \
    --timeout 10m \
    --wait; then
    echo "✅ LiveKit deployment successful"
else
    echo "❌ LiveKit deployment failed"
    
    # Debug information
    echo ""
    echo "🔍 Debug Information:"
    echo "===================="
    
    echo "📋 Helm Status:"
    helm list -n "$LIVEKIT_NAMESPACE" || true
    echo ""
    
    echo "📋 Pod Status:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" -o wide || true
    echo ""
    
    echo "📋 Pod Logs:"
    POD_NAME=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_NAME" ]]; then
        echo "🔍 Logs from pod: $POD_NAME"
        kubectl logs "$POD_NAME" -n "$LIVEKIT_NAMESPACE" --tail=50 || true
    fi
    echo ""
    
    echo "📋 Events:"
    kubectl get events -n "$LIVEKIT_NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
    
    exit 1
fi
echo ""

# =============================================================================
# VERIFICATION
# =============================================================================

echo "✅ Verifying deployment..."

# Wait for pods to be ready
echo "⏳ Waiting for pods to be ready (max 3 minutes)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit-server -n "$LIVEKIT_NAMESPACE" --timeout=180s || true

# Get deployment status
echo ""
echo "📋 Final Status Check:"
kubectl get deployment -n "$LIVEKIT_NAMESPACE"
kubectl get pods -n "$LIVEKIT_NAMESPACE"
kubectl get services -n "$LIVEKIT_NAMESPACE"
kubectl get ingress -n "$LIVEKIT_NAMESPACE"
echo ""

# Get ALB DNS
echo "🌐 Getting ALB DNS name..."
ALB_DNS=""
for i in {1..20}; do
    ALB_DNS=$(kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [[ -n "$ALB_DNS" && "$ALB_DNS" != "null" ]]; then
        echo "✅ ALB DNS: $ALB_DNS"
        break
    fi
    
    echo "   Waiting for ALB DNS... (attempt $i/20)"
    sleep 10
done

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "null" ]]; then
    echo "⚠️ ALB DNS not available yet (this may take a few minutes)"
    ALB_DNS="pending"
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 DEPLOYMENT COMPLETE"
echo "====================="
echo "✅ LiveKit Server deployed successfully!"
echo ""
echo "📋 Connection Details:"
echo "   Domain: https://$LIVEKIT_DOMAIN"
echo "   WebSocket URL: wss://$LIVEKIT_DOMAIN"
echo "   ALB DNS: $ALB_DNS"
echo ""
echo "📋 API Credentials:"
echo "   API Key: $API_KEY"
echo "   API Secret: $API_SECRET"
echo ""
echo "📋 Next Steps:"
echo "   1. Wait 5-10 minutes for ALB to be fully provisioned"
echo "   2. Update Route 53 DNS to point $LIVEKIT_DOMAIN to $ALB_DNS"
echo "   3. Test connection: curl -I https://$LIVEKIT_DOMAIN"
echo "   4. Use the API credentials above in your LiveKit client applications"
echo ""

# Cleanup
rm -f /tmp/livekit-values.yaml

echo "✅ Deployment completed at: $(date)"