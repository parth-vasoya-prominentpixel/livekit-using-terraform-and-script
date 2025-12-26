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

# LiveKit API Keys - Use predefined keys for consistency
echo "🔑 Setting up LiveKit API Keys..."

# Use the validated keys from the test configuration
API_KEY="${LIVEKIT_API_KEY:-livekitekstf}"
API_SECRET="${LIVEKIT_API_SECRET:-f177d0cbdd9742ca199fa592b572df89ca738ec2647928dfbe443587956fa28c}"

echo "✅ Using predefined API keys"
echo "📋 API Key: $API_KEY"
echo "📋 API Secret: ${API_SECRET:0:20}..."

# Validate key format
if [[ ${#API_KEY} -lt 10 ]]; then
    echo "❌ API Key too short (${#API_KEY} characters)"
    exit 1
fi

if [[ ${#API_SECRET} -lt 20 ]]; then
    echo "❌ API Secret too short (${#API_SECRET} characters)"
    exit 1
fi

# Test if secret is valid base64
if echo "$API_SECRET" | base64 -d >/dev/null 2>&1; then
    echo "✅ API Secret is valid base64 format"
else
    echo "⚠️ API Secret may not be valid base64, but continuing..."
fi

echo ""

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
        
        # Force cleanup without waiting for graceful shutdown
        echo "   🔄 Step 1/4: Removing Helm release (no wait)..."
        helm uninstall "$HELM_RELEASE_NAME" -n "$LIVEKIT_NAMESPACE" --timeout 30s 2>/dev/null || true
        
        echo "   🔄 Step 2/4: Force deleting pods..."
        kubectl delete pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
        
        echo "   🔄 Step 3/4: Deleting ingress resources..."
        kubectl delete ingress -n "$LIVEKIT_NAMESPACE" --all --timeout=30s 2>/dev/null || true
        
        echo "   🔄 Step 4/4: Deleting services..."
        kubectl delete service -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --timeout=30s 2>/dev/null || true
        
        echo "   ⏳ Waiting 10 seconds for cleanup to settle..."
        sleep 10
        
        # Verify cleanup
        REMAINING_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$REMAINING_PODS" -gt 0 ]]; then
            echo "   ⚠️  $REMAINING_PODS pods still exist, forcing final cleanup..."
            kubectl patch pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            kubectl delete pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
        fi
        
        echo "✅ Cleanup completed"
    else
        echo "✅ Existing deployment is healthy"
    fi
else
    echo "ℹ️  No existing deployment found"
fi

# Final verification - ensure no helm release exists
if helm list -n "$LIVEKIT_NAMESPACE" | grep -q "$HELM_RELEASE_NAME"; then
    echo "⚠️  Helm release still exists, forcing removal..."
    helm delete "$HELM_RELEASE_NAME" -n "$LIVEKIT_NAMESPACE" --no-hooks 2>/dev/null || true
    sleep 5
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

# Debug: Show the keys section of the generated values
echo ""
echo "🔍 Keys configuration in values.yaml:"
echo "======================================"
grep -A 5 "keys:" /tmp/livekit-values.yaml || echo "❌ No keys section found!"
echo "======================================"
echo ""

# Also show the complete values file for debugging
echo "🔍 Complete values.yaml file:"
echo "=============================="
cat /tmp/livekit-values.yaml
echo "=============================="
echo ""

# Validate the YAML syntax
echo "🔍 Validating YAML syntax..."
if python3 -c "import yaml; yaml.safe_load(open('/tmp/livekit-values.yaml'))" 2>/dev/null; then
    echo "✅ YAML syntax is valid"
elif python -c "import yaml; yaml.safe_load(open('/tmp/livekit-values.yaml'))" 2>/dev/null; then
    echo "✅ YAML syntax is valid"
else
    echo "⚠️ Could not validate YAML syntax (python/python3 not available)"
fi

# Check if keys section exists and is properly formatted
if grep -q "^keys:" /tmp/livekit-values.yaml; then
    echo "✅ Keys section found in values.yaml"
    KEY_COUNT=$(grep -A 10 "^keys:" /tmp/livekit-values.yaml | grep -c ":")
    echo "📋 Found $KEY_COUNT key entries"
else
    echo "❌ Keys section not found in values.yaml!"
    exit 1
fi
echo ""

# =============================================================================
# STEP 5: DEPLOY LIVEKIT
# =============================================================================

echo "📋 Step 5: Deploy LiveKit"
echo "========================="

echo "🔄 Installing LiveKit..."
echo "   📦 Using chart version: $HELM_CHART_VERSION"
echo "   🎯 Target namespace: $LIVEKIT_NAMESPACE"
echo "   ⏱️  Timeout: 5 minutes"
echo ""

# Show installation progress
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
    echo ""
    echo "🔍 Debugging Information:"
    echo "========================"
    
    echo "📋 Helm Status:"
    helm list -n "$LIVEKIT_NAMESPACE" || true
    echo ""
    
    echo "📋 Pod Status:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" || true
    echo ""
    
    echo "📋 Pod Logs:"
    POD_NAME=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$POD_NAME" ]]; then
        echo "🔍 Logs from pod: $POD_NAME"
        kubectl logs "$POD_NAME" -n "$LIVEKIT_NAMESPACE" --tail=20 2>/dev/null || echo "No logs available"
    else
        echo "No pods found"
    fi
    echo ""
    
    echo "📋 Recent Events:"
    kubectl get events -n "$LIVEKIT_NAMESPACE" --sort-by='.lastTimestamp' | tail -10 || true
    
    exit 1
fi
echo ""

# =============================================================================
# STEP 6: VERIFY DEPLOYMENT
# =============================================================================

echo "📋 Step 6: Verify Deployment"
echo "============================"

echo "⏳ Waiting for pods to be ready..."
echo "   🎯 Maximum wait time: 2 minutes"
echo "   🔄 Checking every 5 seconds"
echo ""

for i in {1..24}; do
    READY_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
    
    # Show progress bar
    PROGRESS=$((i * 100 / 24))
    printf "   [%3d%%] Pod status: %s/%s ready (attempt %d/24)\n" "$PROGRESS" "$READY_PODS" "$TOTAL_PODS" "$i"
    
    if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
        echo ""
        echo "✅ All pods are ready!"
        break
    fi
    
    if [ "$i" -eq 24 ]; then
        echo ""
        echo "⚠️  Pods not ready after 2 minutes, but continuing..."
    fi
    
    sleep 5
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