#!/bin/bash

# LiveKit Deployment Script - Simple and Clean
# Following official LiveKit documentation exactly
# Reference: https://docs.livekit.io/deploy/kubernetes/

set -e

echo "🎥 LiveKit Deployment"
echo "===================="
echo "📋 Following official LiveKit documentation"
echo ""

# Find and load configuration file
CONFIG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Look for config files
for config in "$ROOT_DIR/livekit.env" "$SCRIPT_DIR/livekit.env" "./livekit.env"; do
    if [ -f "$config" ]; then
        CONFIG_FILE="$config"
        break
    fi
done

if [ -z "$CONFIG_FILE" ]; then
    echo "❌ Configuration file not found: livekit.env"
    exit 1
fi

echo "📋 Loading configuration from: $CONFIG_FILE"
source "$CONFIG_FILE"
echo "✅ Configuration loaded"

echo ""
echo "📋 Configuration:"
echo "   AWS Region: $AWS_REGION"
echo "   Cluster: $CLUSTER_NAME"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"
echo ""

# Basic verification
echo "🔍 Basic verification..."

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured"
    exit 1
fi

# Update kubeconfig
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1

# Test kubectl
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to cluster"
    exit 1
fi

echo "✅ Basic verification passed"

# Get Redis endpoint from Terraform
echo ""
echo "🔍 Getting Redis endpoint from Terraform..."
TERRAFORM_DIR="$ROOT_DIR/resources"

if [ ! -d "$TERRAFORM_DIR" ]; then
    echo "❌ Terraform directory not found: $TERRAFORM_DIR"
    exit 1
fi

cd "$TERRAFORM_DIR"

REDIS_ENDPOINT=$(terraform output -raw redis_cluster_endpoint 2>/dev/null || echo "")

if [ -z "$REDIS_ENDPOINT" ] || [ "$REDIS_ENDPOINT" = "null" ]; then
    echo "❌ Failed to get Redis endpoint from Terraform"
    echo "💡 Make sure Redis is deployed: terraform output redis_cluster_endpoint"
    exit 1
fi

echo "✅ Redis endpoint: $REDIS_ENDPOINT"
cd "$ROOT_DIR"

# Setup namespace
echo ""
echo "📦 Setting up namespace..."
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    kubectl create namespace "$NAMESPACE"
    echo "✅ Namespace created: $NAMESPACE"
else
    echo "✅ Namespace exists: $NAMESPACE"
fi

# Add LiveKit Helm repository
echo ""
echo "📦 Setting up LiveKit Helm repository..."
helm repo add livekit https://helm.livekit.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
echo "✅ LiveKit Helm repository ready"

# Create simple values.yaml following official docs
echo ""
echo "🔧 Creating LiveKit values.yaml..."
cat > /tmp/livekit-values.yaml << EOF
# LiveKit Configuration - Following Official Documentation
# Refer to https://docs.livekit.io/deploy/kubernetes/

replicaCount: 2

livekit:
  rtc:
    use_external_ip: true
  redis:
    address: $REDIS_ENDPOINT
  keys:
    $API_KEY: $SECRET_KEY

turn:
  enabled: true
  tls_port: 3478

loadBalancer:
  type: alb

# Disable ingress to avoid conflicts
ingress:
  enabled: false

autoscaling:
  enabled: true
  minReplicas: $MIN_REPLICAS
  maxReplicas: $MAX_REPLICAS
  targetCPUUtilizationPercentage: $CPU_THRESHOLD

resources:
  limits:
    cpu: $CPU_LIMIT
    memory: $MEMORY_LIMIT
  requests:
    cpu: $CPU_REQUEST
    memory: $MEMORY_REQUEST
EOF

echo "✅ LiveKit values.yaml created"

# Deploy LiveKit
echo ""
echo "🚀 Deploying LiveKit..."
echo "📋 Release: $RELEASE_NAME"
echo "📋 Chart: livekit/livekit-server"
echo "📋 Namespace: $NAMESPACE"
echo ""

# Check if release exists and clean up if needed
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "� Fogund existing release - checking health..."
    
    # Check if there are any pods
    EXISTING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$EXISTING_PODS" -gt 0 ]; then
        echo "🗑️ Cleaning up existing deployment to avoid conflicts..."
    else
        echo "🗑️ Cleaning up failed deployment..."
    fi
    
    # Force cleanup
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait || true
    
    # Clean up any remaining resources
    kubectl delete ingress -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --ignore-not-found=true || true
    kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 --ignore-not-found=true || true
    
    echo "⏳ Waiting for cleanup to complete..."
    sleep 10
    echo "✅ Cleanup completed - will install fresh"
    
    HELM_ACTION="install"
else
    echo "📋 No existing release found - will install fresh"
    HELM_ACTION="install"
fi

# Deploy LiveKit
echo "🔄 Installing LiveKit..."
helm install "$RELEASE_NAME" livekit/livekit-server \
    -n "$NAMESPACE" \
    -f /tmp/livekit-values.yaml \
    --wait --timeout=10m

echo "✅ LiveKit installed successfully!"

# Wait for LoadBalancer
echo ""
echo "⏳ Waiting for LoadBalancer endpoint..."
LB_ENDPOINT=""
for i in {1..40}; do
    LB_ENDPOINT=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ]; then
        echo "✅ LoadBalancer endpoint ready: $LB_ENDPOINT"
        break
    fi
    
    echo "   Attempt $i/40: LoadBalancer provisioning..."
    sleep 15
done

# Show status
echo ""
echo "📊 Deployment Status:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server
echo ""
kubectl get svc -n "$NAMESPACE"
echo ""

# Final summary
echo "🎉 LiveKit Deployment Complete!"
echo "==============================="
echo ""
echo "📋 Connection Details:"
if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ]; then
    echo "   ✅ WebSocket URL: ws://$LB_ENDPOINT"
    echo "   ✅ HTTP URL: http://$LB_ENDPOINT"
else
    echo "   ⏳ LoadBalancer: Still provisioning"
    echo "   💡 Check: kubectl get svc -n $NAMESPACE $RELEASE_NAME"
fi
echo ""
echo "🔑 API Credentials:"
echo "   📋 API Key: $API_KEY"
echo "   📋 Secret: $SECRET_KEY"
echo ""
echo "📊 Configuration:"
echo "   📋 Redis: $REDIS_ENDPOINT"
echo "   📋 Autoscaling: $MIN_REPLICAS-$MAX_REPLICAS replicas at ${CPU_THRESHOLD}% CPU"
echo ""
echo "📋 Monitoring:"
echo "   - Pods: kubectl get pods -n $NAMESPACE"
echo "   - Service: kubectl get svc -n $NAMESPACE"
echo "   - Logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo ""
echo "💡 LiveKit is ready for WebRTC connections!"
echo "💡 Use the LoadBalancer endpoint above for connections"

# Cleanup
rm -f /tmp/livekit-values.yaml

echo ""
echo "✅ Deployment completed successfully!"