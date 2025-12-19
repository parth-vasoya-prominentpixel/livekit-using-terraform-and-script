#!/bin/bash

# Script to deploy LiveKit on EKS
set -e

echo "🎥 Deploying LiveKit..."

# Check if required environment variables are provided
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name REDIS_ENDPOINT=your-redis-endpoint ./03-deploy-livekit.sh"
    exit 1
fi

if [ -z "$REDIS_ENDPOINT" ]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name REDIS_ENDPOINT=your-redis-endpoint ./03-deploy-livekit.sh"
    exit 1
fi

# Set AWS region (default to us-east-1 if not set)
AWS_REGION=${AWS_REGION:-us-east-1}

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region:  $AWS_REGION"
echo "   Redis:   $REDIS_ENDPOINT"

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Smart namespace handling - avoid conflicts
echo "📦 Handling LiveKit namespace..."
NAMESPACE="livekit"
TIMESTAMP=$(date +%s)

# Check if default namespace exists and has LiveKit deployment
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$NAMESPACE' already exists"
    
    # Check if there's already a LiveKit deployment
    if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit >/dev/null 2>&1; then
        echo "⚠️ Existing LiveKit deployment found in '$NAMESPACE'"
        echo "🔄 Using unique namespace to avoid conflicts"
        NAMESPACE="livekit-terraform-${TIMESTAMP}"
        echo "📦 Creating new namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    else
        echo "✅ Using existing namespace '$NAMESPACE' (no conflicts)"
    fi
else
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
fi

# Add LiveKit Helm repository
echo "📦 Adding LiveKit Helm repository..."
helm repo add livekit https://livekit.github.io/charts
helm repo update

# Update Redis endpoint in values file
echo "🔧 Updating LiveKit values with Redis endpoint..."
cd "$(dirname "$0")/.."

# Create a temporary values file with Redis endpoint
cat > livekit-values-temp.yaml << EOF
# LiveKit configuration
livekit:
  # Redis configuration
  redis:
    address: "$REDIS_ENDPOINT"
  
  # Server configuration
  rtc:
    tcp_port: 7880
    port_range_start: 50000
    port_range_end: 60000
    use_external_ip: true
  
  # Turn server configuration
  turn:
    enabled: true
    domain: ""
    cert_file: ""
    key_file: ""
  
  # Webhook configuration
  webhook:
    api_key: "your-api-key"
    url: ""
  
  # Keys configuration
  keys:
    api_key: "your-api-key"
    api_secret: "your-api-secret"

# Service configuration
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

# Ingress configuration (optional)
ingress:
  enabled: false

# Resource limits
resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 500m
    memory: 512Mi

# Replica count
replicaCount: 2

# Node selector (optional)
nodeSelector: {}

# Tolerations (optional)
tolerations: []

# Affinity (optional)
affinity: {}
EOF

# Smart Helm deployment - avoid conflicts
echo "🚀 Deploying LiveKit..."
RELEASE_NAME="livekit"

# Check if default release exists
if helm list -n "$NAMESPACE" | grep -q "^$RELEASE_NAME\s"; then
    echo "✅ Release '$RELEASE_NAME' already exists in namespace '$NAMESPACE'"
    echo "🔄 Upgrading existing release"
    ACTION="upgrade"
elif [ "$NAMESPACE" != "livekit" ]; then
    # Using unique namespace, safe to use default release name
    echo "📦 Installing new release '$RELEASE_NAME' in namespace '$NAMESPACE'"
    ACTION="install"
else
    # Check if there's any LiveKit release in the namespace
    EXISTING_RELEASE=$(helm list -n "$NAMESPACE" | grep -i livekit | awk '{print $1}' | head -1)
    if [ -n "$EXISTING_RELEASE" ]; then
        echo "⚠️ Found existing LiveKit release: $EXISTING_RELEASE"
        echo "🔄 Using unique release name to avoid conflicts"
        RELEASE_NAME="livekit-terraform-${TIMESTAMP}"
        ACTION="install"
    else
        echo "📦 Installing new release '$RELEASE_NAME'"
        ACTION="install"
    fi
fi

# Deploy based on action
if [ "$ACTION" = "upgrade" ]; then
    helm upgrade "$RELEASE_NAME" livekit/livekit \
        -n "$NAMESPACE" \
        -f livekit-values-temp.yaml \
        --wait --timeout=10m
else
    helm install "$RELEASE_NAME" livekit/livekit \
        -n "$NAMESPACE" \
        -f livekit-values-temp.yaml \
        --wait --timeout=10m
fi

# Clean up temporary file
rm -f livekit-values-temp.yaml

# Wait for pods to be ready
echo "⏳ Waiting for LiveKit pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n "$NAMESPACE" --timeout=300s

# Get deployment status
echo "📊 Deployment Status:"
kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"

# Get LoadBalancer endpoint
echo ""
echo "🌐 Getting LoadBalancer endpoint..."
LB_HOSTNAME=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
if [ "$LB_HOSTNAME" != "pending" ] && [ -n "$LB_HOSTNAME" ]; then
    echo "✅ LiveKit is accessible at: $LB_HOSTNAME"
else
    echo "⏳ LoadBalancer endpoint is still being provisioned..."
    echo "   Run 'kubectl get svc -n $NAMESPACE' to check status"
fi

echo ""
echo "🎉 LiveKit deployment completed successfully!"
echo ""
echo "📋 Deployment Summary:"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"
echo "   Cluster: $CLUSTER_NAME"
echo "   Redis: $REDIS_ENDPOINT"
echo ""
echo "📋 Next steps:"
echo "   1. Wait for LoadBalancer to get an external IP/hostname"
echo "      kubectl get svc -n $NAMESPACE"
echo "   2. Configure your LiveKit client to connect to the endpoint"
echo "   3. Use the API key and secret from the values file"
echo ""
echo "💡 Note: This deployment uses unique names to avoid conflicts with existing setups"