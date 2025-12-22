#!/bin/bash

# LiveKit Deployment Script - Simplified
# Based on official LiveKit documentation
# Reference: https://docs.livekit.io/deploy/kubernetes/

echo "🎥 LiveKit Setup"
echo "================"
echo "📋 LiveKit Server handles WebRTC media processing and room management"
echo "📋 Using ALB Ingress Controller for signal connection"

# Check required environment variables
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export REDIS_ENDPOINT=your-redis-endpoint"
    echo "  export AWS_REGION=us-east-1"
    echo "  ./03-deploy-livekit.sh"
    echo ""
    exit 1
fi

if [ -z "$REDIS_ENDPOINT" ]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export REDIS_ENDPOINT=your-redis-endpoint"
    echo "  export AWS_REGION=us-east-1"
    echo "  ./03-deploy-livekit.sh"
    echo ""
    exit 1
fi

# Set defaults
AWS_REGION=${AWS_REGION:-"us-east-1"}
NAMESPACE="livekit"
RELEASE_NAME="livekit"
DOMAIN="livekit-eks-tf.digi-telephony.com"
TURN_DOMAIN="turn-eks-tf.digi-telephony.com"

echo ""
echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"
echo "   Domain: $DOMAIN"

# Quick verification
echo ""
echo "🔍 Quick verification..."

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured"
    exit 1
fi

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1

# Test kubectl
if ! timeout 10 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to cluster"
    exit 1
fi

echo "✅ AWS and cluster verified"

# Verify Load Balancer Controller
echo ""
echo "🔍 Verifying AWS Load Balancer Controller..."
if ! kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -q "2/2"; then
    echo "❌ AWS Load Balancer Controller not ready"
    echo "💡 Please run: ./02-setup-load-balancer.sh"
    exit 1
fi
echo "✅ Load Balancer Controller is ready"

# Create namespace if needed
echo ""
echo "📦 Setting up namespace..."
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
else
    echo "✅ Namespace '$NAMESPACE' exists"
fi

# Step 1: Add Helm Repository
echo ""
echo "📦 Step 1: Add Helm Repository"

# Remove existing repo if it exists to avoid conflicts
helm repo remove livekit >/dev/null 2>&1 || true

# Add LiveKit repository
echo "🔧 Adding LiveKit Helm repository..."
if helm repo add livekit https://livekit.github.io/charts; then
    echo "✅ LiveKit repository added"
else
    echo "❌ Failed to add LiveKit repository"
    echo "🔄 Trying alternative repository URL..."
    if helm repo add livekit https://helm.livekit.io; then
        echo "✅ LiveKit repository added (alternative URL)"
    else
        echo "❌ Failed to add LiveKit repository with both URLs"
        exit 1
    fi
fi

# Update repositories
echo "🔧 Updating Helm repositories..."
if helm repo update; then
    echo "✅ Helm repositories updated"
else
    echo "❌ Failed to update Helm repositories"
    exit 1
fi

# Verify LiveKit chart is available
echo "🔍 Verifying LiveKit chart availability..."
echo "📋 Searching for available LiveKit charts..."
helm search repo livekit/

# Check for livekit-server chart (correct chart name)
if helm search repo livekit/livekit-server >/dev/null 2>&1; then
    echo "✅ LiveKit server chart found"
    CHART_NAME="livekit-server"
elif helm search repo livekit/livekit >/dev/null 2>&1; then
    echo "✅ LiveKit chart found"
    CHART_NAME="livekit"
else
    echo "❌ No LiveKit chart found in repository"
    echo "📋 Available charts:"
    helm search repo livekit/ || true
    exit 1
fi

echo "📋 Using chart: livekit/$CHART_NAME"

# Step 2: Find SSL Certificate
echo ""
echo "🔍 Step 2: Finding SSL Certificate"
CERT_ARN=""

# Try to find certificate for the specific domain first
echo "🔍 Checking for domain-specific certificate: $DOMAIN"
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text 2>/dev/null || echo "")

if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    echo "✅ Found domain-specific certificate: $(basename "$CERT_ARN")"
else
    # Try wildcard certificate
    echo "🔍 Checking for wildcard certificate: *.digi-telephony.com"
    CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?DomainName=='*.digi-telephony.com'].CertificateArn" --output text 2>/dev/null || echo "")
    
    if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
        echo "✅ Found wildcard certificate: $(basename "$CERT_ARN")"
    else
        # Final fallback to any certificate containing digi-telephony.com
        echo "🔍 Checking for any digi-telephony.com certificate..."
        CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --query "CertificateSummaryList[?contains(DomainName, 'digi-telephony.com')].CertificateArn | [0]" --output text 2>/dev/null || echo "")
        
        if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
            echo "✅ Found fallback certificate: $(basename "$CERT_ARN")"
        else
            echo "❌ No SSL certificate found for digi-telephony.com domain"
            echo "💡 Please create an SSL certificate in ACM for *.digi-telephony.com"
            exit 1
        fi
    fi
fi

echo "📋 Using Certificate ARN: $CERT_ARN"

# Step 3: Deploy LiveKit with Custom Values
echo ""
echo "🚀 Step 3: Deploy LiveKit with Custom Values"

# Create minimal LiveKit values file
echo "🔧 Creating LiveKit values file..."
cat > "livekit-values.yaml" << EOF
# Minimal LiveKit Configuration
# Generated by deployment script

livekit:
  domain: "$DOMAIN"
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: "$REDIS_ENDPOINT"
  keys:
    APIKmrHi78hxpbd: Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

turn:
  enabled: true
  domain: "$TURN_DOMAIN"
  tls_port: 3478
  udp_port: 3478

loadBalancer:
  type: alb
  tls:
    - hosts:
        - "$DOMAIN"
      certificateArn: "$CERT_ARN"
EOF

echo "✅ LiveKit values file created"

cd "$(dirname "$0")/.."

# Deploy LiveKit
echo "🚀 Deploying LiveKit..."
echo "📋 Chart: livekit/$CHART_NAME"
echo "📋 Release: $RELEASE_NAME"
echo "📋 Namespace: $NAMESPACE"

# Check if release exists
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "�  Upgrading existing LiveKit release..."
    HELM_ACTION="upgrade"
else
    echo "🚀 Installing new LiveKit release..."
    HELM_ACTION="install"
fi

echo "📋 Running: helm $HELM_ACTION $RELEASE_NAME livekit/$CHART_NAME -n $NAMESPACE -f scripts/livekit-values.yaml"

if helm "$HELM_ACTION" "$RELEASE_NAME" "livekit/$CHART_NAME" \
    -n "$NAMESPACE" \
    -f scripts/livekit-values.yaml \
    --wait --timeout=10m \
    --debug; then
    
    echo "✅ LiveKit deployment completed successfully!"
else
    echo "❌ LiveKit deployment failed"
    echo ""
    echo "� Troublershooting:"
    echo "📋 Helm status:"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
    echo "📋 Pods:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "   No pods found"
    echo "📋 Events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 || true
    
    # If upgrade failed, try fresh install
    if [ "$HELM_ACTION" = "upgrade" ]; then
        echo "🔄 Upgrade failed, trying fresh install..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
        sleep 5
        
        echo "📋 Running: helm install $RELEASE_NAME livekit/$CHART_NAME -n $NAMESPACE -f scripts/livekit-values.yaml"
        if helm install "$RELEASE_NAME" "livekit/$CHART_NAME" \
            -n "$NAMESPACE" \
            -f scripts/livekit-values.yaml \
            --wait --timeout=10m \
            --debug; then
            
            echo "✅ Fresh install completed successfully!"
        else
            echo "❌ Fresh install also failed"
            exit 1
        fi
    else
        exit 1
    fi
fi

# Step 4: Verify Deployment
echo ""
echo "🔍 Step 4: Verify Deployment"

echo "⏳ Waiting for LiveKit pods to be ready..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n "$NAMESPACE" --timeout=180s; then
    echo "✅ LiveKit pods are ready!"
else
    echo "⚠️ Some pods may still be starting..."
fi

echo ""
echo "📊 Pod Status:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit

echo ""
echo "📊 Service Status:"
kubectl get svc -n "$NAMESPACE"

echo ""
echo "🎉 LiveKit Setup Completed!"
echo "=========================="
echo ""
echo "📋 Summary:"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ Release: $RELEASE_NAME"
echo "   ✅ Domain: $DOMAIN"
echo "   ✅ Redis: $REDIS_ENDPOINT"
echo "   ✅ Certificate: $(basename "$CERT_ARN")"
echo ""
echo "📋 Expected Output: Pods should show READY status"
echo ""
echo "📋 Monitoring Commands:"
echo "   - Check pods: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=livekit"
echo "   - Check services: kubectl get svc -n $NAMESPACE"
echo "   - View logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit"

# Clean up temporary file
rm -f scripts/livekit-values.yaml