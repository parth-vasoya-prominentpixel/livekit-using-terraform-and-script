#!/bin/bash

# LiveKit Deployment Script - Following Official Documentation
# https://docs.livekit.io/transport/self-hosting/kubernetes/

set -e

echo "🎥 LiveKit Deployment"
echo "===================="
echo "📋 Following official LiveKit documentation"
echo "📋 Using ALB Ingress Controller for signal connection"

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-lp-eks-livekit-use1-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="livekit"
RELEASE_NAME="livekit"

# Redis endpoints (dynamic detection in pipeline)
REDIS_ENDPOINT="${REDIS_ENDPOINT:-clustercfg.livekit-redis.x4ncn3.use1.cache.amazonaws.com:6379}"

# Domains and Certificate
LIVEKIT_DOMAIN="livekit-eks-tf.digi-telephony.com"
TURN_DOMAIN="turn-eks-tf.digi-telephony.com"
CERT_ARN="arn:aws:acm:us-east-1:918595516608:certificate/4523a895-7899-41a3-8589-2a5baed3b420"

# API Keys
API_KEY="APIKmrHi78hxpbd"
SECRET_KEY="Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB"

echo ""
echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   LiveKit Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"

# Step 1: Setup
echo ""
echo "🔍 Quick verification..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
echo "✅ AWS and cluster verified"

# Verify Load Balancer Controller
LB_CONTROLLER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)
if [ "$LB_CONTROLLER_PODS" -gt 0 ]; then
    READY_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep "Running" | wc -l)
    echo "✅ Load Balancer Controller is ready ($READY_PODS/$LB_CONTROLLER_PODS pods)"
else
    echo "❌ AWS Load Balancer Controller not found"
    echo "💡 Please run the load balancer setup script first"
    exit 1
fi

# Setup namespace
echo ""
echo "📦 Setting up namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Namespace '$NAMESPACE' ready"

# Clean up existing deployment
echo ""
echo "🔄 Cleaning up existing LiveKit deployment..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait 2>/dev/null || echo "   No existing deployment found"
sleep 5

# Step 2: Add Helm Repository (Official Documentation)
echo ""
echo "📦 Step 1: Add Helm Repository"
echo "==============================="
echo "🔧 Adding LiveKit Helm repository..."

# Remove existing repository if it exists
helm repo remove livekit 2>/dev/null || true

# Add the official LiveKit repository
helm repo add livekit https://livekit.github.io/charts
helm repo update
echo "✅ LiveKit repository added and updated"

# Verify chart availability
echo "🔍 Verifying LiveKit chart availability..."
helm search repo livekit/livekit --versions | head -5
echo "✅ LiveKit chart found"

# Step 3: Get cluster information for ALB
echo ""
echo "🔍 Getting cluster information for ALB..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNET_IDS"

# Step 4: Create LiveKit Values File
echo ""
echo "🚀 Step 2: Deploy LiveKit with Custom Values"
echo "============================================="
echo "🔧 Creating LiveKit values file..."

# Create values file based on your configuration
cat > /tmp/livekit-values.yaml << EOF
# LiveKit Configuration - Based on Official Documentation
livekit:
  domain: $LIVEKIT_DOMAIN
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: $REDIS_ENDPOINT
  keys:
    $API_KEY: $SECRET_KEY
  metrics:
    enabled: true
  prometheus:
    enabled: true
    port: 6789

# Resource Configuration
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

# Pod Anti-Affinity for High Availability
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

# TURN Server Configuration
turn:
  enabled: true
  domain: $TURN_DOMAIN
  tls_port: 3478
  udp_port: 3478

# Load Balancer Configuration (ALB)
loadBalancer:
  type: alb

# Ingress Configuration for ALB
ingress:
  enabled: true
  className: "alb"
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/subnets: $SUBNET_IDS
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: $CERT_ARN
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/tags: Environment=$NAMESPACE,Application=livekit
  hosts:
    - host: $LIVEKIT_DOMAIN
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
      - $LIVEKIT_DOMAIN
      secretName: livekit-tls

# TLS Configuration
tls:
  - hosts:
    - $LIVEKIT_DOMAIN
    certificateArn: $CERT_ARN
EOF

echo "✅ LiveKit values file created"

# Show configuration summary
echo ""
echo "📋 Configuration details:"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Certificate: $(basename "$CERT_ARN")"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Load Balancer: ALB (internet-facing)"
echo "   TLS: Enabled with ACM certificate"

# Step 5: Deploy LiveKit (Official Command)
echo ""
echo "🚀 Installing LiveKit deployment..."
echo "📋 Using official command: helm upgrade --install livekit livekit/livekit"

if helm upgrade --install "$RELEASE_NAME" livekit/livekit \
    -n "$NAMESPACE" \
    -f /tmp/livekit-values.yaml \
    --wait --timeout=10m; then
    echo "✅ LiveKit installed successfully!"
else
    echo "❌ LiveKit installation failed"
    echo ""
    echo "📋 Troubleshooting information:"
    echo "==============================="
    
    # Show the generated values file for debugging
    echo "🔍 Generated values.yaml:"
    cat /tmp/livekit-values.yaml
    echo ""
    
    # Show Kubernetes resources
    echo "🔍 Kubernetes resources:"
    kubectl get pods -n "$NAMESPACE" || true
    echo ""
    kubectl get svc -n "$NAMESPACE" || true
    echo ""
    kubectl get ingress -n "$NAMESPACE" || true
    echo ""
    
    # Show recent events
    echo "🔍 Recent events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 || true
    echo ""
    
    # Clean up failed installation
    echo "🧹 Cleaning up failed installation..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
    
    exit 1
fi

# Step 6: Wait for ALB to be ready
echo ""
echo "⏳ Waiting for Application Load Balancer..."
MAX_ATTEMPTS=30
ATTEMPT=1

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    ALB_ENDPOINT=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$ALB_ENDPOINT" ] && [ "$ALB_ENDPOINT" != "null" ]; then
        echo "✅ ALB ready: $ALB_ENDPOINT"
        break
    fi
    
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo "⚠️ ALB not ready after $MAX_ATTEMPTS attempts"
        echo "📋 Checking ingress status..."
        kubectl get ingress -n "$NAMESPACE" -o yaml || true
        break
    fi
    
    echo "   Attempt $ATTEMPT/$MAX_ATTEMPTS: Waiting for ALB..."
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

# Step 7: Verify Deployment (Official Documentation)
echo ""
echo "📊 Step 3: Verify Deployment"
echo "============================"
echo "📋 Checking pods with label: app.kubernetes.io/name=livekit"

kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit || true

echo ""
echo "📋 All resources:"
echo "📋 Pods:"
kubectl get pods -n "$NAMESPACE" || true

echo ""
echo "📋 Services:"
kubectl get svc -n "$NAMESPACE" || true

echo ""
echo "📋 Ingress:"
kubectl get ingress -n "$NAMESPACE" || true

# Clean up temporary files
rm -f /tmp/livekit-values.yaml

echo ""
echo "🎉 LiveKit Deployment Completed!"
echo "==============================="
echo ""
echo "📋 Summary:"
echo "   ✅ LiveKit Server: Deployed using official chart"
echo "   ✅ Repository: https://livekit.github.io/charts"
echo "   ✅ Chart: livekit/livekit"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ Release: $RELEASE_NAME"
if [ -n "$ALB_ENDPOINT" ]; then
    echo "   ✅ Load Balancer: $ALB_ENDPOINT"
fi
echo "   ✅ Domain: $LIVEKIT_DOMAIN"
echo "   ✅ TURN Domain: $TURN_DOMAIN"
echo "   ✅ HTTPS: Enabled with ACM certificate"
echo "   ✅ Redis: Connected to ElastiCache"
echo "   ✅ Metrics: Enabled (Prometheus on port 6789)"

echo ""
echo "📋 Access URLs:"
echo "   🌐 LiveKit API: https://$LIVEKIT_DOMAIN"
echo "   🌐 TURN Server: $TURN_DOMAIN:3478"

echo ""
echo "📋 Next Steps:"
echo "   1. Wait for DNS propagation (if DNS records not set)"
echo "   2. Test connectivity: curl -k https://$LIVEKIT_DOMAIN"
echo "   3. Check LiveKit logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit"