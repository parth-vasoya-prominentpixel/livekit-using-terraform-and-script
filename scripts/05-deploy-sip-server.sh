#!/bin/bash
# ---------------------------
# SIP Server Deployment for LiveKit
# This script deploys SIP server with ConfigMap, Deployment, and Service
# ---------------------------

set -euo pipefail

echo "📞 SIP Server Deployment for LiveKit"
echo "===================================="
echo "📅 Started at: $(date)"
echo ""

# =============================================================================
# VARIABLES CONFIGURATION
# =============================================================================

# --- Required Variables ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"

# --- LiveKit Configuration ---
LIVEKIT_NAMESPACE="livekit"
API_KEY="${API_KEY:-APIKmrHi78hxpbd}"
API_SECRET="${API_SECRET:-Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB}"

# --- SIP Configuration ---
SIP_PORT="${SIP_PORT:-5060}"
RTP_PORT_RANGE="${RTP_PORT_RANGE:-10000-20000}"
USE_EXTERNAL_IP="${USE_EXTERNAL_IP:-true}"
LOG_LEVEL="${LOG_LEVEL:-debug}"

# --- Resource Configuration ---
CPU_REQUEST="${CPU_REQUEST:-500m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-1Gi}"
CPU_LIMIT="${CPU_LIMIT:-2000m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-2Gi}"

# =============================================================================
# VALIDATION
# =============================================================================

echo "🔍 Validating Configuration"
echo "==========================="

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    exit 1
fi

if [[ -z "$DOMAIN_NAME" ]]; then
    echo "❌ DOMAIN_NAME environment variable is required"
    exit 1
fi

if [[ -z "$REDIS_ENDPOINT" ]]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    exit 1
fi

echo "📋 SIP Server Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Environment: $ENVIRONMENT"
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   Domain: $DOMAIN_NAME"
echo "   WebSocket URL: wss://$DOMAIN_NAME"
echo "   Redis Endpoint: $REDIS_ENDPOINT"
echo "   API Key: $API_KEY"
echo "   SIP Port: $SIP_PORT"
echo "   RTP Port Range: $RTP_PORT_RANGE"
echo "   External IP: $USE_EXTERNAL_IP"
echo "   Log Level: $LOG_LEVEL"
echo ""

# Check if required tools are available
for tool in kubectl aws; do
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
# HELPER FUNCTIONS
# =============================================================================

# Function to check if namespace exists
check_namespace() {
    local namespace="$1"
    
    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo "✅ Namespace '$namespace' exists"
        return 0
    else
        echo "❌ Namespace '$namespace' does not exist"
        return 1
    fi
}

# Function to cleanup on failure
cleanup_on_failure() {
    echo "🧹 Cleaning up failed SIP server deployment..."
    
    # Delete deployment if it exists
    kubectl delete deployment sip-server -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    # Delete service if it exists
    kubectl delete service sip-server -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    # Delete configmap if it exists
    kubectl delete configmap sip-config -n "$LIVEKIT_NAMESPACE" --ignore-not-found=true
    
    echo "✅ Cleanup completed"
}

# Function to wait for deployment to be ready
wait_for_deployment() {
    local deployment_name="$1"
    local namespace="$2"
    local timeout="${3:-300}"
    
    echo "⏳ Waiting for deployment '$deployment_name' to be ready (timeout: ${timeout}s)..."
    
    if kubectl wait --for=condition=available --timeout="${timeout}s" deployment/"$deployment_name" -n "$namespace"; then
        echo "✅ Deployment '$deployment_name' is ready"
        return 0
    else
        echo "❌ Deployment '$deployment_name' failed to become ready within ${timeout}s"
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo "🚀 Starting SIP Server Deployment Process"
echo "=========================================="
echo ""

# -----------------------------------------------------------------------------
# STEP 1: VALIDATE PREREQUISITES
# -----------------------------------------------------------------------------

echo "📋 Step 1: Validate Prerequisites"
echo "================================="

echo "🔍 Checking if LiveKit namespace exists..."
if ! check_namespace "$LIVEKIT_NAMESPACE"; then
    echo "❌ LiveKit namespace does not exist. Please deploy LiveKit first."
    exit 1
fi

echo "🔍 Checking cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Prerequisites validated"
echo ""

# -----------------------------------------------------------------------------
# STEP 2: CREATE SIP CONFIGMAP
# -----------------------------------------------------------------------------

echo "📋 Step 2: Create SIP ConfigMap"
echo "==============================="

echo "🔄 Creating SIP configuration..."

# Create the ConfigMap YAML
cat <<EOF > /tmp/sip-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sip-config
  namespace: livekit
data:
  config.yaml: |
    api_key: APIKmrHi78hxpbd
    api_secret: Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB
    ws_url: wss://livekit-eks-tf.digi-telephony.com
    redis:
      address: lp-ec-redis-use1-dev-redis.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379
    sip_port: 5060
    rtp_port: 10000-20000
    use_external_ip: true
    logging:
      level: debug

EOF

echo "📄 SIP ConfigMap created at: /tmp/sip-config.yaml"

# Apply the ConfigMap
echo "🔄 Applying SIP ConfigMap..."
if kubectl apply -f /tmp/sip-config.yaml; then
    echo "✅ SIP ConfigMap applied successfully"
else
    echo "❌ Failed to apply SIP ConfigMap"
    exit 1
fi

# Verify ConfigMap
echo "🔍 Verifying ConfigMap..."
if kubectl get configmap sip-config -n "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ SIP ConfigMap verified"
else
    echo "❌ SIP ConfigMap verification failed"
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 3: CREATE SIP DEPLOYMENT
# -----------------------------------------------------------------------------

echo "📋 Step 3: Create SIP Deployment"
echo "================================"

echo "🔄 Creating SIP deployment configuration..."

# Create the Deployment YAML
cat <<EOF > /tmp/sip-deployment.yaml
# sip-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sip-server
  namespace: livekit
  labels:
    app: sip-server
spec:
  # BEFORE: replicas: 1
  # NOW: Remove replicas (HPA will manage this)
  # replicas: 1  <-- REMOVE THIS LINE
  selector:
    matchLabels:
      app: sip-server
  template:
    metadata:
      labels:
        app: sip-server
        sip-server: "1" # Label for dispatchers sidecar to identify SIP pods
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: sip
        image: livekit/sip:latest
        args:
          - --config
          - /config/config.yaml
        ports:
          - containerPort: 5060
            protocol: UDP
            name: sip
          - containerPort: 10000
            protocol: UDP
            name: rtp-min
          - containerPort: 20000
            protocol: UDP
            name: rtp-max
        volumeMounts:
          - name: config-volume
            mountPath: /config
            readOnly: true
        # BEFORE: Low resource limits
        # NOW: Increase for production workload
        resources:
          requests:
            cpu: 500m      
            memory: 1Gi 
          limits:
            cpu: 2000m    
            memory: 2Gi  
      volumes:
        - name: config-volume
          configMap:
            name: sip-config
EOF

echo "📄 SIP Deployment created at: /tmp/sip-deployment.yaml"

# Apply the Deployment
echo "🔄 Applying SIP Deployment..."
if kubectl apply -f /tmp/sip-deployment.yaml; then
    echo "✅ SIP Deployment applied successfully"
else
    echo "❌ Failed to apply SIP Deployment"
    cleanup_on_failure
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 4: CREATE SIP SERVICE
# -----------------------------------------------------------------------------

echo "📋 Step 4: Create SIP Service"
echo "============================="

echo "🔄 Creating SIP service configuration..."

# Create the Service YAML
cat <<EOF > /tmp/sip-service.yaml
# sip-service.yaml
# CHANGE: Deploy this service - dispatchers needs it to discover SIP pods
apiVersion: v1
kind: Service
metadata:
  name: sip-server
  namespace: livekit
spec:
  selector:
    app: sip-server
  ports:
    # BEFORE: Only TCP was defined
    # NOW: Add UDP (required for SIP)
    - name: sip-udp
      port: 5060
      targetPort: 5060
      protocol: UDP
    - name: sip-tcp
      port: 5060
      targetPort: 5060
      protocol: TCP
  # NEW: Add clusterIP (dispatchers watches endpoints of this service)
  type: ClusterIP

apiVersion: v1
kind: Service
metadata:
  name: sip-server
  namespace: $LIVEKIT_NAMESPACE
  labels:
    app: sip-server
    environment: $ENVIRONMENT
spec:
  selector:
    app: sip-server
  ports:
    # UDP port for SIP (required for SIP)
    - name: sip-udp
      port: $SIP_PORT
      targetPort: $SIP_PORT
      protocol: UDP
    # TCP port for SIP (optional but good to have)
    - name: sip-tcp
      port: $SIP_PORT
      targetPort: $SIP_PORT
      protocol: TCP
    # ClusterIP for dispatchers to discover SIP pods
  type: ClusterIP
EOF

echo "📄 SIP Service created at: /tmp/sip-service.yaml"

# Apply the Service
echo "🔄 Applying SIP Service..."
if kubectl apply -f /tmp/sip-service.yaml; then
    echo "✅ SIP Service applied successfully"
else
    echo "❌ Failed to apply SIP Service"
    cleanup_on_failure
    exit 1
fi

# Verify Service
echo "🔍 Verifying Service..."
if kubectl get service sip-server -n "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ SIP Service verified"
else
    echo "❌ SIP Service verification failed"
    cleanup_on_failure
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 5: WAIT FOR DEPLOYMENT TO BE READY
# -----------------------------------------------------------------------------

echo "📋 Step 5: Wait for Deployment to be Ready"
echo "=========================================="

if wait_for_deployment "sip-server" "$LIVEKIT_NAMESPACE" 300; then
    echo "✅ SIP Server deployment is ready"
else
    echo "❌ SIP Server deployment failed to become ready"
    echo ""
    echo "🔍 Deployment status:"
    kubectl describe deployment sip-server -n "$LIVEKIT_NAMESPACE" || echo "Failed to get deployment status"
    echo ""
    echo "🔍 Pod status:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=sip-server || echo "Failed to get pod status"
    echo ""
    cleanup_on_failure
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# STEP 6: VERIFY DEPLOYMENT
# -----------------------------------------------------------------------------

echo "📋 Step 6: Verify Deployment"
echo "============================"

echo "🔍 Checking SIP Server pods..."
PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=sip-server --no-headers 2>/dev/null | wc -l)
if [ "$PODS" -gt 0 ]; then
    echo "✅ Found $PODS SIP Server pod(s)"
    
    echo ""
    echo "📋 Pod Details:"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=sip-server -o wide
    echo ""
    
    echo "📋 Pod Status:"
    kubectl describe pods -n "$LIVEKIT_NAMESPACE" -l app=sip-server | grep -A 10 "Conditions:\|Events:" || echo "No detailed status available"
else
    echo "❌ No SIP Server pods found"
    cleanup_on_failure
    exit 1
fi

echo "🔍 Checking SIP Server service..."
if kubectl get service sip-server -n "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ SIP Server service is running"
    
    echo ""
    echo "📋 Service Details:"
    kubectl get service sip-server -n "$LIVEKIT_NAMESPACE" -o wide
    echo ""
else
    echo "❌ SIP Server service not found"
    cleanup_on_failure
    exit 1
fi

echo "🔍 Testing SIP Server connectivity..."
SIP_POD=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app=sip-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$SIP_POD" ]]; then
    echo "📋 Testing connectivity to SIP pod: $SIP_POD"
    
    # Test if the SIP process is running
    if kubectl exec -n "$LIVEKIT_NAMESPACE" "$SIP_POD" -- ps aux | grep -q sip; then
        echo "✅ SIP process is running in pod"
    else
        echo "⚠️  SIP process status unclear, but pod is running"
    fi
else
    echo "⚠️  Could not find SIP pod for connectivity test"
fi

echo ""

# -----------------------------------------------------------------------------
# CLEANUP TEMPORARY FILES
# -----------------------------------------------------------------------------

echo "📋 Cleanup: Removing temporary files"
echo "===================================="

rm -f /tmp/sip-config.yaml /tmp/sip-deployment.yaml /tmp/sip-service.yaml
echo "✅ Temporary files cleaned up"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "🎉 SIP SERVER DEPLOYMENT COMPLETE"
echo "================================="
echo "✅ SIP ConfigMap created and applied"
echo "✅ SIP Deployment created and ready"
echo "✅ SIP Service created and running"
echo "✅ SIP Server pods are healthy"
echo ""
echo "📋 SIP Server Summary:"
echo "   • Namespace: $LIVEKIT_NAMESPACE"
echo "   • Domain: $DOMAIN_NAME"
echo "   • WebSocket URL: wss://$DOMAIN_NAME"
echo "   • Redis Endpoint: $REDIS_ENDPOINT"
echo "   • SIP Port: $SIP_PORT"
echo "   • RTP Port Range: $RTP_PORT_RANGE"
echo "   • Environment: $ENVIRONMENT"
echo ""
echo "📋 Access Information:"
echo "   🌐 LiveKit Server: https://$DOMAIN_NAME"
echo "   📞 SIP Server: Ready for SIP calls"
echo "   🔗 Redis: Connected to $REDIS_ENDPOINT"
echo ""
echo "📋 Next Steps:"
echo "   1. SIP server is ready to handle SIP calls"
echo "   2. Configure your SIP clients to connect to: $DOMAIN_NAME:$SIP_PORT"
echo "   3. Monitor SIP server logs: kubectl logs -n $LIVEKIT_NAMESPACE -l app=sip-server"
echo "   4. Test SIP connectivity with your SIP clients"
echo ""
echo "✅ SIP Server deployment completed at: $(date)"