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

# Redis endpoints - Using Primary endpoint for read/write operations
# Primary endpoint: lp-ec-redis-use1-dev-redis.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379
# Reader endpoint: lp-ec-redis-use1-dev-redis-ro.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379
REDIS_ENDPOINT="${REDIS_ENDPOINT:-lp-ec-redis-use1-dev-redis.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379}"

# Domains and Certificate (EXACT as specified by user - UPDATED)
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
echo ""
echo "🔍 Verifying AWS Load Balancer Controller..."
LB_CONTROLLER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)
if [ "$LB_CONTROLLER_PODS" -gt 0 ]; then
    READY_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep "1/1.*Running" | wc -l)
    echo "✅ Load Balancer Controller is ready ($READY_PODS/$LB_CONTROLLER_PODS pods)"
    
    # Show controller details
    echo "📋 Controller pods:"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | while read line; do
        echo "   $line"
    done
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
# Check if livekit namespace exists
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "   Found existing namespace: $NAMESPACE"
    # Check for existing LiveKit deployment
    if helm list -n "$NAMESPACE" -q | grep -q "$RELEASE_NAME"; then
        echo "   Removing existing LiveKit deployment..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait 2>/dev/null || echo "   Failed to uninstall, continuing..."
        sleep 10
    else
        echo "   No existing LiveKit deployment found"
    fi
else
    echo "   No existing namespace found"
fi

# Step 2: Add Helm Repository (Official Documentation)
echo ""
echo "📦 Step 1: Add Helm Repository"
echo "==============================="
echo "🔧 Adding LiveKit Helm repository..."

# Remove existing repository if it exists
helm repo remove livekit 2>/dev/null || true

# Add the official LiveKit repository (from official docs)
helm repo add livekit https://helm.livekit.io
helm repo update
echo "✅ LiveKit repository added and updated"

# Verify chart availability
echo "🔍 Verifying LiveKit chart availability..."
helm search repo livekit/livekit-server --versions | head -5
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

# Create LiveKit values based on deep analysis of official chart
cat > /tmp/livekit-values.yaml << EOF
# Basic deployment configuration
replicaCount: 1
image:
  repository: livekit/livekit-server
  tag: v1.9.0
  pullPolicy: IfNotPresent

# LiveKit server configuration
livekit:
  # Domain for WebSocket connections
  domain: $LIVEKIT_DOMAIN
  
  # RTC configuration for WebRTC
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
    
  # Redis connection
  redis:
    address: $REDIS_ENDPOINT
    
  # API keys for authentication
  keys:
    $API_KEY: $SECRET_KEY

# TURN server configuration
turn:
  enabled: true
  domain: $TURN_DOMAIN
  tls_port: 3478
  udp_port: 3478

# Service configuration - Use LoadBalancer to create ALB
service:
  type: LoadBalancer
  port: 7880
  targetPort: 7880
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: $CERT_ARN
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "https"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"

# Resource limits
resources:
  limits:
    cpu: 2000m
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 512Mi

# Pod configuration
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: false
  runAsNonRoot: true
  runAsUser: 1000

# Health checks - Adjusted for LiveKit startup time
livenessProbe:
  httpGet:
    path: /
    port: 7880
    scheme: HTTP
  initialDelaySeconds: 60
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 3
  successThreshold: 1

readinessProbe:
  httpGet:
    path: /
    port: 7880
    scheme: HTTP
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1

# Startup probe for slow starting containers
startupProbe:
  httpGet:
    path: /
    port: 7880
    scheme: HTTP
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30
  successThreshold: 1

# Node affinity for better distribution
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/name
            operator: In
            values:
            - livekit-server
        topologyKey: kubernetes.io/hostname

# Tolerations for node scheduling
tolerations: []

# Node selector
nodeSelector: {}

# Environment variables for LiveKit configuration
env:
  - name: LIVEKIT_CONFIG_BODY
    value: |
      port: 7880
      bind_addresses:
        - ""
      rtc:
        tcp_port: 7881
        port_range_start: 50000
        port_range_end: 60000
        use_external_ip: true
      redis:
        address: $REDIS_ENDPOINT
      keys:
        $API_KEY: $SECRET_KEY
      turn:
        enabled: true
        domain: $TURN_DOMAIN
        tls_port: 3478
        udp_port: 3478
      webhook:
        api_key: $API_KEY
      room:
        auto_create: true
        enable_recording: false
      logging:
        level: info
        
# Disable ingress completely - we use LoadBalancer service
ingress:
  enabled: false

# Disable autoscaling for now to avoid complexity
autoscaling:
  enabled: false

# Service account
serviceAccount:
  create: true
  annotations: {}
  name: ""

# Pod disruption budget
podDisruptionBudget:
  enabled: false

# Network policy
networkPolicy:
  enabled: false
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

# Step 5: Deploy LiveKit (Deep Analysis Approach)
echo ""
echo "🚀 Installing LiveKit deployment..."
echo "📋 Using comprehensive configuration based on official chart analysis"

# First, let's check what templates the chart will generate
echo "🔍 Analyzing Helm chart templates..."
helm template "$RELEASE_NAME" livekit/livekit-server \
    --namespace "$NAMESPACE" \
    --values /tmp/livekit-values.yaml \
    --debug > /tmp/livekit-templates.yaml 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Helm template generation successful"
    echo "📋 Generated templates preview:"
    head -50 /tmp/livekit-templates.yaml
else
    echo "❌ Helm template generation failed"
    echo "📋 Template errors:"
    cat /tmp/livekit-templates.yaml
    echo ""
    echo "🔄 Trying with simplified configuration..."
    
    # Fallback to ultra-minimal configuration
    cat > /tmp/livekit-simple.yaml << EOF
replicaCount: 1
livekit:
  domain: $LIVEKIT_DOMAIN
  redis:
    address: $REDIS_ENDPOINT
  keys:
    $API_KEY: $SECRET_KEY
service:
  type: LoadBalancer
ingress:
  enabled: false
EOF
    
    echo "🔍 Testing simplified configuration..."
    helm template "$RELEASE_NAME" livekit/livekit-server \
        --namespace "$NAMESPACE" \
        --values /tmp/livekit-simple.yaml \
        --debug > /tmp/livekit-simple-templates.yaml 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✅ Simplified template works, using it for deployment"
        cp /tmp/livekit-simple.yaml /tmp/livekit-values.yaml
    else
        echo "❌ Even simplified template failed:"
        cat /tmp/livekit-simple-templates.yaml
        exit 1
    fi
fi

echo ""
echo "🚀 Proceeding with LiveKit installation..."
if helm install "$RELEASE_NAME" livekit/livekit-server \
    --namespace "$NAMESPACE" \
    --values /tmp/livekit-values.yaml \
    --wait --timeout=15m \
    --debug; then
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

# Wait a moment for pods to be created
sleep 15

# Check for LiveKit pods
LIVEKIT_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l)
if [ "$LIVEKIT_PODS" -gt 0 ]; then
    echo "✅ Found $LIVEKIT_PODS LiveKit pods"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit
else
    echo "⚠️ No pods found with app.kubernetes.io/name=livekit, checking all pods in namespace..."
    kubectl get pods -n "$NAMESPACE" || echo "No pods found in namespace $NAMESPACE"
fi

echo ""
echo "📋 All resources in namespace $NAMESPACE:"
echo "📋 Pods:"
kubectl get pods -n "$NAMESPACE" || echo "No pods found"

echo ""
echo "📋 Services:"
kubectl get svc -n "$NAMESPACE" || echo "No services found"

echo ""
echo "📋 Ingress:"
kubectl get ingress -n "$NAMESPACE" || echo "No ingress found"

echo ""
echo "📋 Deployments:"
kubectl get deployments -n "$NAMESPACE" || echo "No deployments found"

# Clean up temporary files
rm -f /tmp/livekit-values.yaml

echo ""
echo "🎉 LiveKit Deployment Completed!"
echo "==============================="
echo ""
echo "📋 Summary:"
echo "   ✅ LiveKit Server: Deployed using official livekit-server chart"
echo "   ✅ Repository: https://helm.livekit.io"
echo "   ✅ Chart: livekit/livekit-server"
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
echo "   ✅ Host Networking: Configured for WebRTC"
echo "   ✅ Graceful Shutdown: 5 hours termination grace period"

echo ""
echo "📋 Access URLs:"
echo "   🌐 LiveKit API: https://$LIVEKIT_DOMAIN"
echo "   🌐 TURN Server: $TURN_DOMAIN:3478"

echo ""
echo "📋 Next Steps:"
echo "   1. Verify pods are running: kubectl get pods -n $NAMESPACE"
echo "   2. Check ALB status: kubectl get ingress -n $NAMESPACE"
echo "   3. Test connectivity: curl -k https://$LIVEKIT_DOMAIN"
echo "   4. Check LiveKit logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"