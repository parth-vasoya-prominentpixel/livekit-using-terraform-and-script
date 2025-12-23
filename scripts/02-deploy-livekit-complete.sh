#!/bin/bash

# Complete LiveKit Deployment Script
# Combines AWS Load Balancer Controller setup + LiveKit deployment
# Based on official documentation: https://docs.livekit.io/transport/self-hosting/kubernetes/

set -e

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
echo "   Wildcard Domain: $WILDCARD_DOMAIN"
echo "   Namespace: $LIVEKIT_NAMESPACE"
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
# PART 1: AWS LOAD BALANCER CONTROLLER SETUP
# =============================================================================

echo "🔧 PART 1: AWS Load Balancer Controller Setup"
echo "=============================================="

# Step 1: Download and create IAM policy
echo "📋 Step 1: Setting up IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_NAME"
    echo "   Using existing policy: $POLICY_ARN"
else
    echo "🔄 Creating IAM policy: $POLICY_NAME"
    
    # Download the latest policy document from official AWS Load Balancer Controller
    curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
    
    # Create the policy
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --description "IAM policy for AWS Load Balancer Controller"
    
    echo "✅ IAM policy created: $POLICY_ARN"
    
    # Clean up
    rm -f iam_policy.json
fi
echo ""

# Step 2: Create IAM role and service account using eksctl
echo "📋 Step 2: Setting up service account and IAM role..."

# Check if service account already exists with proper IAM role
if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Service account already exists: $SERVICE_ACCOUNT_NAME"
    
    # Get the existing role ARN
    EXISTING_ROLE_ARN=$(kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_ROLE_ARN" ]]; then
        echo "   Using existing IAM role: $EXISTING_ROLE_ARN"
        ROLE_ARN="$EXISTING_ROLE_ARN"
        
        # Verify the role has the correct policy attached
        ROLE_NAME_FROM_ARN=$(echo "$EXISTING_ROLE_ARN" | cut -d'/' -f2)
        if aws iam list-attached-role-policies --role-name "$ROLE_NAME_FROM_ARN" | grep -q "$POLICY_NAME"; then
            echo "   ✅ IAM role has correct policy attached"
        else
            echo "   ⚠️  IAM role exists but policy may not be attached"
        fi
    else
        echo "⚠️  Service account exists but has no IAM role annotation"
        echo "   Deleting and recreating service account with proper IAM role..."
        kubectl delete serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$LB_NAMESPACE"
        
        # Create new service account with IAM role
        eksctl create iamserviceaccount \
            --cluster="$CLUSTER_NAME" \
            --namespace="$LB_NAMESPACE" \
            --name="$SERVICE_ACCOUNT_NAME" \
            --role-name="$ROLE_NAME" \
            --attach-policy-arn="$POLICY_ARN" \
            --region="$AWS_REGION" \
            --approve
        
        ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
        echo "✅ Service account recreated with IAM role: $ROLE_ARN"
    fi
else
    echo "🔄 Creating service account with IAM role..."
    
    # Create service account with IAM role using eksctl
    eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace="$LB_NAMESPACE" \
        --name="$SERVICE_ACCOUNT_NAME" \
        --role-name="$ROLE_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --region="$AWS_REGION" \
        --approve
    
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    echo "✅ Service account created with IAM role: $ROLE_ARN"
fi
echo ""

# Step 3: Add EKS Helm repository
echo "📋 Step 3: Setting up Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
echo "✅ EKS Helm repository added and updated"
echo ""

# Step 4: Install AWS Load Balancer Controller using Helm
echo "📋 Step 4: Installing AWS Load Balancer Controller..."

# Check if the controller is already installed
if helm list -n "$LB_NAMESPACE" | grep -q aws-load-balancer-controller; then
    echo "✅ AWS Load Balancer Controller already installed"
    echo "🔄 Upgrading to ensure latest configuration..."
    
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n "$LB_NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --version="$HELM_CHART_VERSION" \
        --wait \
        --timeout=300s
    
    echo "✅ AWS Load Balancer Controller upgraded successfully"
else
    echo "🔄 Installing AWS Load Balancer Controller..."
    
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n "$LB_NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --version="$HELM_CHART_VERSION" \
        --wait \
        --timeout=300s
    
    echo "✅ AWS Load Balancer Controller installed successfully"
fi
echo ""

# Step 5: Verify Load Balancer Controller installation
echo "📋 Step 5: Verifying Load Balancer Controller installation..."

# Wait for deployment to be ready
echo "⏳ Waiting for controller deployment to be ready..."
if kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n "$LB_NAMESPACE"; then
    echo "✅ AWS Load Balancer Controller deployment is ready"
else
    echo "❌ AWS Load Balancer Controller deployment failed to become ready"
    kubectl describe deployment aws-load-balancer-controller -n "$LB_NAMESPACE"
    exit 1
fi

# Check deployment status
echo ""
echo "🔍 Load Balancer Controller Status:"
kubectl get deployment -n "$LB_NAMESPACE" aws-load-balancer-controller

# Verify pods are running
READY_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | wc -l)

if [[ "$READY_PODS" -gt 0 ]] && [[ "$READY_PODS" -eq "$TOTAL_PODS" ]]; then
    echo "✅ All Load Balancer Controller pods are running ($READY_PODS/$TOTAL_PODS)"
else
    echo "❌ Load Balancer Controller pods not ready: $READY_PODS/$TOTAL_PODS running"
    kubectl describe pods -n "$LB_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    exit 1
fi
echo ""

# =============================================================================
# PART 2: LIVEKIT DEPLOYMENT
# =============================================================================

echo "🎥 PART 2: LiveKit Deployment"
echo "============================="

# Step 6: Add LiveKit Helm repository
echo "📋 Step 6: Adding LiveKit Helm repository..."
if helm repo list | grep -q "livekit"; then
    echo "✅ LiveKit Helm repository already added"
else
    echo "🔄 Adding LiveKit Helm repository..."
    helm repo add livekit https://helm.livekit.io
fi

helm repo update
echo "✅ LiveKit Helm repositories updated"
echo ""

# Step 7: Create LiveKit namespace
echo "📋 Step 7: Creating LiveKit namespace..."
if kubectl get namespace "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' already exists"
else
    kubectl create namespace "$LIVEKIT_NAMESPACE"
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' created"
fi
echo ""

# Step 8: Create LiveKit values.yaml
echo "📋 Step 8: Creating LiveKit values.yaml..."
cat > livekit-values.yaml << EOF
# LiveKit Helm Chart Values for digi-telephony.com
# Production configuration matching your existing deployment

livekit:
  domain: ${LIVEKIT_DOMAIN}
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  
  # Redis configuration
  redis:
    address: ${REDIS_ENDPOINT}
  
  # API keys configuration
  keys:
    ${API_KEY}: ${SECRET_KEY}
  
  # Metrics configuration
  metrics:
    enabled: true
    prometheus:
      enabled: true
      port: 6789

# Resource configuration
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

# Pod anti-affinity for better distribution
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

# TURN server configuration
turn:
  enabled: true
  domain: ${TURN_DOMAIN}
  tls_port: 3478
  udp_port: 3478
  # No secretName needed - will use ALB certificate

# Load Balancer configuration for AWS ALB
loadBalancer:
  type: alb
  tls:
    - hosts:
        - ${LIVEKIT_DOMAIN}
      certificateArn: ${CERTIFICATE_ARN}

# Service configuration
service:
  type: ClusterIP

# Ingress configuration for ALB with your certificate
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
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS-1-2-2017-01
    # Health check configuration
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '30'
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '5'
    alb.ingress.kubernetes.io/healthy-threshold-count: '2'
    alb.ingress.kubernetes.io/unhealthy-threshold-count: '3'
    
  hosts:
    - host: ${LIVEKIT_DOMAIN}
      paths:
        - path: /
          pathType: Prefix

# Autoscaling configuration
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 60

# Security context
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000

# Pod security context
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000

# Service account
serviceAccount:
  create: true
  annotations: {}
  name: ""

# Node selector (optional)
nodeSelector: {}

# Tolerations (optional)
tolerations: []
EOF

echo "✅ LiveKit values.yaml created with your exact configuration"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Certificate ARN: $CERTIFICATE_ARN"
echo ""

# Step 9: Certificate Configuration
echo "📋 Step 9: Certificate Configuration..."
echo ""
echo "🔐 Using ACM Certificate for *.digi-telephony.com"
echo "   Certificate ARN: $CERTIFICATE_ARN"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo ""
echo "✅ Certificate configuration ready"
echo ""

# Step 10: Deploy LiveKit
echo "📋 Step 10: Deploying LiveKit..."

if helm list -n "$LIVEKIT_NAMESPACE" | grep -q "$LIVEKIT_RELEASE"; then
    echo "✅ LiveKit already installed, upgrading..."
    helm upgrade "$LIVEKIT_RELEASE" livekit/livekit \
        -n "$LIVEKIT_NAMESPACE" \
        -f livekit-values.yaml \
        --wait \
        --timeout=600s
    echo "✅ LiveKit upgraded successfully"
else
    echo "🔄 Installing LiveKit..."
    helm install "$LIVEKIT_RELEASE" livekit/livekit \
        -n "$LIVEKIT_NAMESPACE" \
        -f livekit-values.yaml \
        --wait \
        --timeout=600s
    echo "✅ LiveKit installed successfully"
fi
echo ""

# Step 11: Verify LiveKit deployment
echo "📋 Step 12: Verifying LiveKit deployment..."

# Wait for deployment to be ready
echo "⏳ Waiting for LiveKit deployment to be ready..."
if kubectl wait --for=condition=available --timeout=300s deployment/$LIVEKIT_RELEASE -n "$LIVEKIT_NAMESPACE"; then
    echo "✅ LiveKit deployment is ready"
else
    echo "❌ LiveKit deployment failed to become ready"
    kubectl describe deployment/$LIVEKIT_RELEASE -n "$LIVEKIT_NAMESPACE"
    exit 1
fi

# Check deployment status
echo ""
echo "🔍 LiveKit Deployment Status:"
kubectl get deployment -n "$LIVEKIT_NAMESPACE"

# Check pod status
echo ""
echo "🔍 LiveKit Pod Status:"
kubectl get pods -n "$LIVEKIT_NAMESPACE"

# Check service status
echo ""
echo "🔍 LiveKit Service Status:"
kubectl get services -n "$LIVEKIT_NAMESPACE"

# Check ingress status
echo ""
echo "🔍 LiveKit Ingress Status:"
kubectl get ingress -n "$LIVEKIT_NAMESPACE"

# Get ALB address
ALB_ADDRESS=$(kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [[ -n "$ALB_ADDRESS" ]]; then
    echo ""
    echo "🌐 Application Load Balancer:"
    echo "   Address: $ALB_ADDRESS"
    echo "   HTTP URL: http://$ALB_ADDRESS"
    if [[ "$USE_ACM_CERT" == "true" || "$USE_TLS_SECRET" == "true" ]]; then
        echo "   HTTPS URL: https://$ALB_ADDRESS"
        echo "   Custom Domain: https://$LIVEKIT_DOMAIN"
    else
        echo "   Custom Domain: http://$LIVEKIT_DOMAIN (configure DNS + TLS)"
    fi
else
    echo ""
    echo "⏳ ALB is still provisioning. Check status with:"
    echo "   kubectl get ingress -n $LIVEKIT_NAMESPACE"
fi

echo ""

# =============================================================================
# FINAL SUMMARY
# =============================================================================

echo "🎉 Complete LiveKit Deployment Finished!"
echo "========================================"
echo ""
echo "📋 Deployment Summary:"
echo "   ✅ AWS Load Balancer Controller: Ready"
echo "   ✅ LiveKit Namespace: $LIVEKIT_NAMESPACE"
echo "   ✅ LiveKit Release: $LIVEKIT_RELEASE"
echo "   ✅ Redis Endpoint: $REDIS_ENDPOINT"
echo "   ✅ LiveKit Domain: $LIVEKIT_DOMAIN"
echo "   ✅ TURN Domain: $TURN_DOMAIN"
echo "   ✅ API Key: $API_KEY"
echo "   ✅ Certificate ARN: $CERTIFICATE_ARN"
if [[ -n "$ALB_ADDRESS" ]]; then
    echo "   ✅ Load Balancer: $ALB_ADDRESS"
else
    echo "   ⏳ Load Balancer: Provisioning..."
fi
echo ""
echo "🔧 Next Steps:"
echo "   1. Wait for ALB to be fully provisioned (2-3 minutes)"
echo "   2. Configure DNS records:"
echo "      - $LIVEKIT_DOMAIN → $ALB_ADDRESS"
echo "      - $TURN_DOMAIN → $ALB_ADDRESS"
echo "   3. Test HTTPS connectivity"
echo ""
echo "🧪 Testing Commands:"
echo "   - Check status: kubectl get all -n $LIVEKIT_NAMESPACE"
echo "   - View logs: kubectl logs -n $LIVEKIT_NAMESPACE -l app.kubernetes.io/name=livekit"
echo "   - Port forward: kubectl port-forward -n $LIVEKIT_NAMESPACE svc/$LIVEKIT_RELEASE 7880:7880"
echo ""
echo "📚 Documentation:"
echo "   - https://docs.livekit.io/transport/self-hosting/kubernetes/"
echo "   - https://kubernetes-sigs.github.io/aws-load-balancer-controller/"
echo ""
echo "🎯 Your LiveKit server is ready at:"
echo "   https://$LIVEKIT_DOMAIN"
echo "   TURN server: $TURN_DOMAIN:3478"
echo ""