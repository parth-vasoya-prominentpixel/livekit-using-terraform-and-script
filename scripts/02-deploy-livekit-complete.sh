#!/bin/bash

# Complete LiveKit Deployment Script
# Following official AWS documentation: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
# Step-by-step implementation with proper error handling

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
CERTIFICATE_ARN="arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414"

# LiveKit configuration
LIVEKIT_NAMESPACE="livekit"
LIVEKIT_RELEASE="livekit"
API_KEY="${API_KEY:-APIKmrHi78hxpbd}"
SECRET_KEY="${SECRET_KEY:-Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB}"

# AWS Load Balancer Controller configuration (UNIQUE NAMES)
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller-livekit"
LB_NAMESPACE="kube-system"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-LiveKit"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole-LiveKit"
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
echo "   Service Account: $SERVICE_ACCOUNT_NAME"
echo "   IAM Role: $ROLE_NAME"
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
# PART 1: AWS LOAD BALANCER CONTROLLER SETUP (OFFICIAL AWS DOCUMENTATION)
# =============================================================================

echo "🔧 PART 1: AWS Load Balancer Controller Setup"
echo "=============================================="
echo "Following: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html"
echo ""

# Step 1: Check and clean up any failed installations
echo "📋 Step 1: Checking existing installations..."

# Check if our specific Helm release exists and is failed
if helm list -n "$LB_NAMESPACE" -q | grep -q "aws-load-balancer-controller"; then
    echo "⚠️  Found existing aws-load-balancer-controller Helm release"
    
    # Check if it's failed
    RELEASE_STATUS=$(helm list -n "$LB_NAMESPACE" -f "aws-load-balancer-controller" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    if [[ "$RELEASE_STATUS" == "failed" ]]; then
        echo "🧹 Removing failed Helm release..."
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE"
        sleep 5
        echo "✅ Failed release removed"
    else
        echo "ℹ️  Existing release status: $RELEASE_STATUS"
    fi
fi

# Check if deployment exists but is unhealthy
if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    # Handle null values
    if [[ "${READY_REPLICAS}" == "null" || "${READY_REPLICAS}" == "" ]]; then
        READY_REPLICAS="0"
    fi
    if [[ "${DESIRED_REPLICAS}" == "null" || "${DESIRED_REPLICAS}" == "" ]]; then
        DESIRED_REPLICAS="0"
    fi
    
    echo "ℹ️  Found existing deployment: ${READY_REPLICAS}/${DESIRED_REPLICAS} replicas ready"
    
    if [[ "${READY_REPLICAS}" -eq 0 && "${DESIRED_REPLICAS}" -gt 0 ]]; then
        echo "🧹 Deployment is unhealthy (0 ready replicas), removing..."
        kubectl delete deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
        
        # Also remove the Helm release if it exists
        helm uninstall aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null || true
        
        sleep 10
        echo "✅ Unhealthy deployment removed"
    elif [[ "${READY_REPLICAS}" -gt 0 ]]; then
        echo "✅ Existing deployment is healthy, will skip installation"
        SKIP_LBC_INSTALL="true"
    fi
fi

echo "✅ Installation check completed"
echo ""

# Step 2: Download IAM policy (as per AWS docs)
echo "📋 Step 2: Setting up IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
else
    echo "🔄 Creating IAM policy: $POLICY_NAME"
    echo "   Downloading policy from AWS documentation..."
    
    # Download the IAM policy as per AWS docs
    curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
    
    # Create the policy
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --description "IAM policy for AWS Load Balancer Controller (LiveKit)"
    
    # Clean up
    rm -f iam_policy.json
    
    echo "✅ IAM policy created: $POLICY_ARN"
fi
echo ""

# Step 3: Install cert-manager (if not already installed)
echo "📋 Step 3: Installing cert-manager..."

if kubectl get namespace cert-manager >/dev/null 2>&1; then
    echo "✅ cert-manager namespace already exists"
else
    echo "🔄 Installing cert-manager..."
    kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.13.0/cert-manager.yaml
    
    # Wait for cert-manager to be ready
    echo "   Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    
    echo "✅ cert-manager installed and ready"
fi
echo ""

# Step 4: Create IAM service account (as per AWS docs)
echo "📋 Step 4: Creating IAM service account..."

# Check if our specific service account exists
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_ROLE_ARN" && "$EXISTING_ROLE_ARN" != "null" ]]; then
        echo "✅ Service account already exists with IAM role: $EXISTING_ROLE_ARN"
        ROLE_ARN="$EXISTING_ROLE_ARN"
    else
        echo "⚠️  Service account exists but no IAM role annotation"
        echo "   Recreating service account with proper IAM role..."
        kubectl delete serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE"
        sleep 2
    fi
fi

# Create service account if it doesn't exist or needs IAM role
if ! kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "🔄 Creating service account with IAM role using eksctl..."
    
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
    echo "✅ Service account created with IAM role: $ROLE_ARN"
fi

# Verify service account
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account verified: $SERVICE_ACCOUNT_NAME"
else
    echo "❌ Service account verification failed"
    exit 1
fi
echo ""

# Step 5: Install AWS Load Balancer Controller using Helm (as per AWS docs)
echo "📋 Step 5: Installing AWS Load Balancer Controller using Helm..."

# Add EKS Helm repository
echo "🔄 Adding EKS Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
echo "✅ EKS Helm repository added and updated"

# Install or skip based on existing deployment health
if [[ "${SKIP_LBC_INSTALL:-false}" == "true" ]]; then
    echo "✅ Skipping installation - healthy deployment already exists"
else
    echo "🔄 Installing AWS Load Balancer Controller..."
    
    # Install using Helm as per AWS documentation
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

# Step 6: Verify the installation (as per AWS docs)
echo "📋 Step 6: Verifying AWS Load Balancer Controller installation..."

# Wait for deployment to be created
echo "⏳ Waiting for deployment to be created..."
for i in {1..30}; do
    if kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
        echo "✅ Deployment found"
        break
    else
        echo "   Waiting for deployment... (attempt $i/30)"
        sleep 2
    fi
done

# Verify deployment exists
if ! kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "❌ Deployment not found after installation"
    echo "🔍 Checking Helm releases:"
    helm list -n "$LB_NAMESPACE"
    exit 1
fi

# Wait for pods to be created and ready
echo "⏳ Waiting for pods to be ready..."
if kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n "$LB_NAMESPACE" 2>/dev/null; then
    echo "✅ AWS Load Balancer Controller is ready"
else
    echo "⚠️  Deployment not ready within timeout, checking status..."
    
    # Show current status
    kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
    kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    
    # Check if any pods are running
    RUNNING_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    
    if [[ "$RUNNING_PODS" -gt 0 ]]; then
        echo "✅ Some pods are running ($RUNNING_PODS), continuing..."
    else
        echo "❌ No pods are running"
        echo "🔍 Pod details:"
        kubectl describe pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null | tail -30
        echo ""
        echo "❌ Load Balancer Controller is not working"
        exit 1
    fi
fi

# Final verification - check webhook service
echo "🔍 Verifying webhook service..."
for i in {1..30}; do
    if kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" >/dev/null 2>&1; then
        ENDPOINTS=$(kubectl get endpoints aws-load-balancer-webhook-service -n "$LB_NAMESPACE" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
        if [[ -n "$ENDPOINTS" && "$ENDPOINTS" != "null" && "$ENDPOINTS" != "[]" ]]; then
            echo "✅ Webhook service is ready with endpoints"
            break
        fi
    fi
    echo "   Waiting for webhook service... (attempt $i/30)"
    sleep 2
done

# Show final status
echo ""
echo "🔍 Final AWS Load Balancer Controller Status:"
kubectl get deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get service aws-load-balancer-webhook-service -n "$LB_NAMESPACE" 2>/dev/null || echo "Webhook service not found"

FINAL_RUNNING=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "$FINAL_RUNNING" -gt 0 ]]; then
    echo "✅ AWS Load Balancer Controller is ready ($FINAL_RUNNING pods running)"
else
    echo "❌ AWS Load Balancer Controller is not ready"
    exit 1
fi
echo ""

# =============================================================================
# PART 2: LIVEKIT DEPLOYMENT
# =============================================================================

echo "🎥 PART 2: LiveKit Deployment"
echo "============================="

# Step 7: Add LiveKit Helm repository
echo "📋 Step 7: Adding LiveKit Helm repository..."
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

# Step 8: Create LiveKit namespace
echo "📋 Step 8: Creating LiveKit namespace..."
if kubectl get namespace "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' already exists"
else
    kubectl create namespace "$LIVEKIT_NAMESPACE"
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' created"
fi
echo ""

# Step 9: Create LiveKit values.yaml
echo "📋 Step 9: Creating LiveKit values.yaml..."
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

# Step 10: Deploy LiveKit
echo "📋 Step 10: Deploying LiveKit..."

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

# Step 11: Wait for LiveKit to be ready
echo "📋 Step 11: Waiting for LiveKit to be ready..."

echo "⏳ Waiting for LiveKit deployment (up to 5 minutes)..."
if kubectl wait --for=condition=available --timeout=300s deployment/$LIVEKIT_RELEASE -n "$LIVEKIT_NAMESPACE" 2>/dev/null; then
    echo "✅ LiveKit deployment is ready"
else
    echo "⚠️  LiveKit not ready within timeout, checking status..."
    kubectl get deployment -n "$LIVEKIT_NAMESPACE" || echo "No deployments found"
    kubectl get pods -n "$LIVEKIT_NAMESPACE" || echo "No pods found"
fi
echo ""

# Step 12: Check ALB provisioning
echo "📋 Step 12: Checking ALB provisioning..."

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