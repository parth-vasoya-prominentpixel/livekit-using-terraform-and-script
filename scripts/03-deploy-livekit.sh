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

# Create namespace
echo "📦 Creating LiveKit namespace..."
kubectl create namespace livekit --dry-run=client -o yaml | kubectl apply -f -

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

# Deploy LiveKit
echo "🚀 Deploying LiveKit..."
helm upgrade --install livekit livekit/livekit \
    -n livekit \
    -f livekit-values-temp.yaml \
    --wait --timeout=10m

# Clean up temporary file
rm -f livekit-values-temp.yaml

# Wait for pods to be ready
echo "⏳ Waiting for LiveKit pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n livekit --timeout=300s

# Get deployment status
echo "📊 Deployment Status:"
kubectl get pods -n livekit
kubectl get svc -n livekit

# Get LoadBalancer endpoint
echo ""
echo "🌐 Getting LoadBalancer endpoint..."
LB_HOSTNAME=$(kubectl get svc -n livekit -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
if [ "$LB_HOSTNAME" != "pending" ] && [ -n "$LB_HOSTNAME" ]; then
    echo "✅ LiveKit is accessible at: $LB_HOSTNAME"
else
    echo "⏳ LoadBalancer endpoint is still being provisioned..."
    echo "   Run 'kubectl get svc -n livekit' to check status"
fi

echo ""
echo "🎉 LiveKit deployment completed successfully!"
echo ""
echo "📋 Next steps:"
echo "   1. Wait for LoadBalancer to get an external IP/hostname"
echo "   2. Configure your LiveKit client to connect to the endpoint"
echo "   3. Use the API key and secret from the values file"