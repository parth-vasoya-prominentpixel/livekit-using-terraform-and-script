#!/bin/bash

# Complete LiveKit Deployment Script
# Proper order: CRDs -> Service Account -> Load Balancer Controller -> LiveKit
# Production-ready with proper error handling and no circular dependencies

set -euo pipefail

echo "🎥 Complete LiveKit Deployment"
echo "=============================="

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# Domain configuration
LIVEKIT_DOMAIN="livekit-tf.digi-telephony.com"
TURN_DOMAIN="turn-livekit-tf.digi-telephony.com"
WILDCARD_DOMAIN="*.digi-telephony.com"
CERTIFICATE_ARN="arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414"

# LiveKit configuration
LIVEKIT_NAMESPACE="livekit"
LIVEKIT_RELEASE="livekit"
API_KEY="${API_KEY:-APIKmrHi78hxpbd}"
SECRET_KEY="${SECRET_KEY:-Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB}"

# AWS Load Balancer Controller configuration
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
LB_NAMESPACE="kube-system"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
HELM_CHART_VERSION="1.14.0"

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
echo "   Redis: $REDIS_ENDPOINT"
echo "   LiveKit Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verify required tools
echo "🔧 Verifying required tools..."
for tool in aws kubectl helm eksctl jq curl wget; do
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
    kubectl get nodes
else
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo ""

# =============================================================================
# PART 1: AWS LOAD BALANCER CONTROLLER SETUP (PROPER ORDER)
# =============================================================================

echo "🔧 PART 1: AWS Load Balancer Controller Setup"
echo "=============================================="

# Step 1: Clean up any failed installations first
echo "📋 Step 1: Cleaning up any failed installations..."

# Remove any failed Helm releases
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller"; then
    RELEASE_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    if [[ "$RELEASE_STATUS" == "failed" ]]; then
        echo "🧹 Removing failed Helm release..."
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE" || true
        sleep 5
    fi
fi

# Check deployment health
if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    if [[ "${READY_REPLICAS}" == "null" || "${READY_REPLICAS}" == "" ]]; then
        READY_REPLICAS="0"
    fi
    if [[ "${DESIRED_REPLICAS}" == "null" || "${DESIRED_REPLICAS}" == "" ]]; then
        DESIRED_REPLICAS="0"
    fi
    
    if [[ "${READY_REPLICAS}" -eq 0 && "${DESIRED_REPLICAS}" -gt 0 ]]; then
        echo "🧹 Removing unhealthy deployment (0/${DESIRED_REPLICAS} ready)..."
        kubectl delete deployment aws-load-balancer-controller -n "$LB_NAMESPACE" || true
        sleep 10
    elif [[ "${READY_REPLICAS}" -gt 0 ]]; then
        echo "✅ Existing deployment is healthy (${READY_REPLICAS}/${DESIRED_REPLICAS} ready)"
    fi
fi

echo "✅ Cleanup completed"
echo ""

# Step 2: Setup IAM policy
echo "📋 Step 2: Setting up IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
else
    echo "🔄 Creating IAM policy: $POLICY_NAME"
    curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --description "IAM policy for AWS Load Balancer Controller"
    rm -f iam_policy.json
    echo "✅ IAM policy created: $POLICY_ARN"
fi
echo ""

# Step 3: Install CRDs FIRST (before anything else)
echo "📋 Step 3: Installing CRDs (required first)..."
if kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null 2>&1; then
    echo "✅ CRDs already installed"
else
    echo "🔄 Installing CRDs..."
    wget -q https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml -O /tmp/crds.yaml
    kubectl apply -f /tmp/crds.yaml
    rm -f /tmp/crds.yaml
    echo "✅ CRDs installed successfully"
fi
echo ""

# Step 4: Setup Helm repository
echo "📋 Step 4: Setting up Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
echo "✅ EKS Helm repository ready"
echo ""

# Step 5: Create service account with IAM role
echo "📋 Step 5: Setting up service account and IAM role..."

# Check if service account exists and is properly configured
SA_EXISTS=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1 && echo "true" || echo "false")

if [[ "$SA_EXISTS" == "true" ]]; then
    EXISTING_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_ROLE_ARN" && "$EXISTING_ROLE_ARN" != "null" ]]; then
        echo "✅ Service account exists with IAM role: $EXISTING_ROLE_ARN"
        ROLE_ARN="$EXISTING_ROLE_ARN"
    else
        echo "⚠️  Service account exists but no IAM role annotation - using existing"
        ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    fi
else
    echo "🔄 Creating service account with IAM role..."
    
    # Create with eksctl
    eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace="$LB_NAMESPACE" \
        --name="$SERVICE_ACCOUNT_NAME" \
        --role-name="$ROLE_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --region="$AWS_REGION" \
        --override-existing-serviceaccounts \
        --approve
    
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    echo "✅ Service account created: $ROLE_ARN"
fi

# Final verification
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account verified: $SERVICE_ACCOUNT_NAME"
else
    echo "❌ Service account verification failed"
    exit 1
fi
echo ""

# Step 6: Install AWS Load Balancer Controller
echo "📋 Step 6: Installing AWS Load Balancer Controller..."

# Check current status
LBC_DEPLOYED=$(helm list -n "$LB_NAMESPACE" -q | grep -c "aws-load-balancer-controller" || echo "0")
LBC_HEALTHY="false"

if [[ "$LBC_DEPLOYED" -gt 0 ]]; then
    LBC_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    if [[ "$LBC_STATUS" == "deployed" ]]; then
        # Check if deployment is actually healthy
        if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
            READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "${READY_REPLICAS}" != "null" && "${READY_REPLICAS}" != "" && "${READY_REPLICAS}" -gt 0 ]]; then
                echo "✅ Load Balancer Controller already deployed and healthy (${READY_REPLICAS} replicas)"
                LBC_HEALTHY="true"
            fi
        fi
    fi
fi

# Install if not healthy
if [[ "$LBC_HEALTHY" != "true" ]]; then
    echo "🔄 Installing AWS Load Balancer Controller..."
    
    # Remove existing if needed
    if [[ "$LBC_DEPLOYED" -gt 0 ]]; then
        echo "   Removing existing installation..."
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE" || true
        sleep 5
    fi
    
    # Fresh installation
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n "$LB_NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --version="$HELM_CHART_VERSION"
    
    echo "✅ Helm installation completed"
fi
echo ""

# Step 7: Wait for Load Balancer Controller to be ready
echo "📋 Step 7: Waiting for Load Balancer Controller to be ready..."

echo "⏳ Waiting for deployment to be available (up to 5 minutes)..."
if kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null; then
    echo "✅ Load Balancer Controller deployment is ready"
else
    echo "⚠️  Deployment not ready within 5 minutes, checking status..."
    
    # Check current status
    kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" || echo "Deployment not found"
    kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller || echo "No pods found"
    
    # Check if any pods are running
    RUNNING_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    
    if [[ "$RUNNING_PODS" -gt 0 ]]; then
        echo "✅ Some pods are running ($RUNNING_PODS), continuing..."
    else
        echo "❌ No pods are running, checking for issues..."
        kubectl describe pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null | tail -20 || echo "No pods to describe"
        echo ""
        echo "❌ Load Balancer Controller is not working, cannot proceed"
        exit 1
    fi
fi

# Final verification
echo "🔍 Final Load Balancer Controller Status:"
kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null || echo "Deployment not found"
kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null || echo "No pods found"

FINAL_RUNNING=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "$FINAL_RUNNING" -gt 0 ]]; then
    echo "✅ Load Balancer Controller is ready ($FINAL_RUNNING pods running)"
else
    echo "❌ Load Balancer Controller is not ready"
    exit 1
fi
echo ""

# =============================================================================
# PART 2: LIVEKIT DEPLOYMENT (ONLY AFTER LOAD BALANCER CONTROLLER IS READY)
# =============================================================================

echo "🎥 PART 2: LiveKit Deployment"
echo "============================="

# Step 8: Add LiveKit Helm repository
echo "📋 Step 8: Adding LiveKit Helm repository..."
if helm repo list | grep -q "livekit"; then
    echo "✅ LiveKit repository already added"
else
    helm repo add livekit https://helm.livekit.io
fi

helm repo update
echo "✅ LiveKit repository updated"

# Verify chart availability
echo "🔍 Verifying LiveKit chart..."
if helm search repo livekit/livekit-server >/dev/null 2>&1; then
    LIVEKIT_CHART="livekit/livekit-server"
    echo "✅ Using chart: $LIVEKIT_CHART"
else
    echo "❌ LiveKit chart not found"
    helm search repo livekit/
    exit 1
fi
echo ""

# Step 9: Create LiveKit namespace
echo "📋 Step 9: Creating LiveKit namespace..."
if kubectl get namespace "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' already exists"
else
    kubectl create namespace "$LIVEKIT_NAMESPACE"
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' created"
fi
echo ""

# Step 10: Create LiveKit values.yaml
echo "📋 Step 10: Creating LiveKit values.yaml..."
cat > livekit-values.yaml << EOF
# LiveKit Configuration for digi-telephony.com
livekit:
  domain: ${LIVEKIT_DOMAIN}
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: ${REDIS_ENDPOINT}
  keys:
    ${API_KEY}: ${SECRET_KEY}

# Resources
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

# TURN server
turn:
  enabled: true
  domain: ${TURN_DOMAIN}
  tls_port: 3478
  udp_port: 3478

# Service (ClusterIP for ALB)
service:
  type: ClusterIP

# Ingress for ALB
ingress:
  enabled: true
  className: alb
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: ${CERTIFICATE_ARN}
    alb.ingress.kubernetes.io/ssl-redirect: '443'
  hosts:
    - host: ${LIVEKIT_DOMAIN}
      paths:
        - path: /
          pathType: Prefix

# Autoscaling
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 60
EOF

echo "✅ LiveKit values.yaml created"
echo ""

# Step 11: Deploy LiveKit
echo "📋 Step 11: Deploying LiveKit..."

# Check if already installed
LIVEKIT_DEPLOYED=$(helm list -n "$LIVEKIT_NAMESPACE" -q | grep -c "$LIVEKIT_RELEASE" || echo "0")

if [[ "$LIVEKIT_DEPLOYED" -gt 0 ]]; then
    echo "✅ LiveKit already installed, upgrading..."
    
    helm upgrade "$LIVEKIT_RELEASE" "$LIVEKIT_CHART" \
        -n "$LIVEKIT_NAMESPACE" \
        -f livekit-values.yaml
    
    echo "✅ LiveKit upgraded successfully"
else
    echo "🔄 Installing LiveKit..."
    
    helm install "$LIVEKIT_RELEASE" "$LIVEKIT_CHART" \
        -n "$LIVEKIT_NAMESPACE" \
        -f livekit-values.yaml
    
    echo "✅ LiveKit installed successfully"
fi
echo ""

# Step 12: Wait for LiveKit to be ready
echo "📋 Step 12: Waiting for LiveKit to be ready..."

echo "⏳ Waiting for LiveKit deployment (up to 5 minutes)..."
if kubectl wait --for=condition=available --timeout=300s deployment/$LIVEKIT_RELEASE -n "$LIVEKIT_NAMESPACE" 2>/dev/null; then
    echo "✅ LiveKit deployment is ready"
else
    echo "⚠️  LiveKit not ready within timeout, checking status..."
    kubectl get deployment -n "$LIVEKIT_NAMESPACE" || echo "No deployments found"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" || echo "No pods found"
fi
echo ""

# Step 13: Check ALB provisioning
echo "📋 Step 13: Checking ALB provisioning..."

echo "⏳ Waiting for ALB to be provisioned (up to 3 minutes)..."
ALB_ADDRESS=""
for i in {1..18}; do  # 18 * 10 seconds = 3 minutes
    ALB_ADDRESS=$(kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "$ALB_ADDRESS" ]]; then
        echo "✅ ALB provisioned: $ALB_ADDRESS"
        break
    else
        echo "   Waiting for ALB... (attempt $i/18)"
        sleep 10
    fi
done

if [[ -z "$ALB_ADDRESS" ]]; then
    echo "⚠️  ALB still provisioning, check later with:"
    echo "   kubectl get ingress -n $LIVEKIT_NAMESPACE"
fi
echo ""

# =============================================================================
# FINAL SUMMARY
# =============================================================================

echo "🎉 LiveKit Deployment Complete!"
echo "==============================="
echo ""
echo "📊 Status Summary:"
echo "   ✅ Load Balancer Controller: Ready"
echo "   ✅ LiveKit Server: Deployed"
echo "   ✅ Namespace: $LIVEKIT_NAMESPACE"
echo "   ✅ Domain: $LIVEKIT_DOMAIN"
echo "   ✅ TURN Domain: $TURN_DOMAIN"
if [[ -n "$ALB_ADDRESS" ]]; then
    echo "   ✅ ALB: $ALB_ADDRESS"
else
    echo "   ⏳ ALB: Provisioning..."
fi
echo ""
echo "🌐 Access URLs:"
if [[ -n "$ALB_ADDRESS" ]]; then
    echo "   - Direct: https://$ALB_ADDRESS"
fi
echo "   - Domain: https://$LIVEKIT_DOMAIN"
echo "   - TURN: $TURN_DOMAIN:3478"
echo ""
echo "🔧 Monitoring Commands:"
echo "   kubectl get all -n $LIVEKIT_NAMESPACE"
echo "   kubectl get ingress -n $LIVEKIT_NAMESPACE"
echo "   kubectl logs -n $LIVEKIT_NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo ""
echo "✅ Deployment successful!"