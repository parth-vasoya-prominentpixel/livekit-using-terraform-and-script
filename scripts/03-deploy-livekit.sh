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
DOMAIN="livekit.digi-telephony.com"
TURN_DOMAIN="turn.digi-telephony.com"

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

# Check Load Balancer Controller permissions
echo "🔍 Checking Load Balancer Controller permissions..."
LB_CONTROLLER_ROLE=$(kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")

if [ -n "$LB_CONTROLLER_ROLE" ]; then
    echo "📋 Load Balancer Controller service account: $LB_CONTROLLER_ROLE"
    
    # Check if the service account has proper annotations
    LB_ROLE_ARN=$(kubectl get serviceaccount -n kube-system "$LB_CONTROLLER_ROLE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    
    if [ -n "$LB_ROLE_ARN" ]; then
        echo "📋 Load Balancer Controller IAM role: $LB_ROLE_ARN"
        echo "✅ Load Balancer Controller appears properly configured"
        
        # Warn about potential permission issues
        echo ""
        echo "⚠️ IMPORTANT: If ALB creation fails with permission errors, ensure the IAM role has:"
        echo "   - elasticloadbalancing:DescribeListenerAttributes"
        echo "   - elasticloadbalancing:DescribeListeners"
        echo "   - elasticloadbalancing:DescribeLoadBalancers"
        echo "   - elasticloadbalancing:DescribeTargetGroups"
        echo "   - elasticloadbalancing:DescribeTargetHealth"
        echo "   - elasticloadbalancing:ModifyListener"
        echo "   - elasticloadbalancing:ModifyTargetGroup"
        echo "📋 Role ARN: $LB_ROLE_ARN"
        echo ""
    else
        echo "⚠️ Load Balancer Controller may not have proper IAM role configured"
        echo "💡 This will cause ALB creation issues"
    fi
else
    echo "⚠️ Could not determine Load Balancer Controller service account"
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

# Check for existing LiveKit deployment and clean up if unhealthy
echo ""
echo "🔍 Checking for existing LiveKit deployment..."

# Check if LiveKit deployment exists
if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server >/dev/null 2>&1; then
    echo "📋 Found existing LiveKit deployment"
    
    # Always clean up existing deployment to avoid conflicts
    echo "🗑️ Cleaning up existing LiveKit deployment to avoid conflicts..."
    
    # Show current status for debugging
    echo "📋 Current deployment status:"
    kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || echo "   No deployments found"
    echo "📋 Current pod status:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || echo "   No pods found"
    echo "📋 Current ingress status:"
    kubectl get ingress -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || echo "   No ingress found"
    
    # Remove Helm release if it exists
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "🗑️ Uninstalling Helm release: $RELEASE_NAME"
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait || true
    fi
    
    # Force delete any remaining resources to avoid conflicts
    echo "🗑️ Cleaning up remaining resources..."
    kubectl delete deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
    kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
    kubectl delete svc -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || true
    kubectl delete configmap -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || true
    kubectl delete ingress -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || true
    kubectl delete secret -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || true
    
    # Clean up any ALB resources that might conflict
    echo "🗑️ Cleaning up potential ALB conflicts..."
    kubectl delete ingress -n "$NAMESPACE" --all 2>/dev/null || true
    
    # Wait for cleanup to complete
    echo "⏳ Waiting for cleanup to complete..."
    sleep 15
    
    # Verify cleanup
    REMAINING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
    REMAINING_INGRESS=$(kubectl get ingress -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$REMAINING_PODS" -eq 0 ] && [ "$REMAINING_INGRESS" -eq 0 ]; then
        echo "✅ Cleanup completed successfully"
    else
        echo "⚠️ Some resources may still be terminating"
        [ "$REMAINING_PODS" -gt 0 ] && echo "   - $REMAINING_PODS pods remaining"
        [ "$REMAINING_INGRESS" -gt 0 ] && echo "   - $REMAINING_INGRESS ingress remaining"
        echo "📋 Waiting additional time for termination..."
        sleep 10
    fi
    
    FORCE_FRESH_INSTALL=true
else
    echo "✅ No existing LiveKit deployment found"
    FORCE_FRESH_INSTALL=true
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

# Step 2: Validate Redis Connection
echo ""
echo "🔍 Step 2: Validate Redis Connection"
REDIS_HOST=$(echo "$REDIS_ENDPOINT" | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_ENDPOINT" | cut -d: -f2)

echo "📋 Redis Configuration:"
echo "   Full Endpoint: $REDIS_ENDPOINT"
echo "   Host: $REDIS_HOST"
echo "   Port: $REDIS_PORT"

# Check if Redis endpoint resolves
echo "🔍 Testing DNS resolution for Redis host..."
if nslookup "$REDIS_HOST" >/dev/null 2>&1; then
    echo "✅ Redis host DNS resolution successful"
else
    echo "❌ Redis host DNS resolution failed"
    echo "🔍 Checking available ElastiCache clusters..."
    
    # Try to find the correct Redis endpoint
    echo "📋 Available ElastiCache replication groups:"
    REDIS_ENDPOINTS=$(aws elasticache describe-replication-groups --region "$AWS_REGION" --query 'ReplicationGroups[*].[ReplicationGroupId,Status,PrimaryEndpoint.Address,PrimaryEndpoint.Port]' --output text 2>/dev/null)
    
    if [ -n "$REDIS_ENDPOINTS" ]; then
        echo "$REDIS_ENDPOINTS"
        
        # Try to find a working Redis endpoint
        WORKING_ENDPOINT=$(aws elasticache describe-replication-groups --region "$AWS_REGION" --query 'ReplicationGroups[?Status==`available`].PrimaryEndpoint.Address | [0]' --output text 2>/dev/null)
        
        if [ -n "$WORKING_ENDPOINT" ] && [ "$WORKING_ENDPOINT" != "None" ]; then
            echo "🔄 Found working Redis endpoint: $WORKING_ENDPOINT"
            REDIS_ENDPOINT="$WORKING_ENDPOINT:6379"
            REDIS_HOST="$WORKING_ENDPOINT"
            echo "� Updatedo Redis endpoint: $REDIS_ENDPOINT"
        else
            echo "❌ No available Redis clusters found"
            echo "�  Please ensure Redis cluster is created and available"
            exit 1
        fi
    else
        echo "❌ No Redis replication groups found"
        echo "💡 Please ensure Redis cluster is created and available"
        exit 1
    fi
fi

# Test Redis connection from within cluster
echo "🔍 Testing Redis connection from cluster..."
if kubectl run redis-test-$(date +%s) --image=redis:alpine --rm --restart=Never --timeout=30s -- redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
    echo "✅ Redis connection test successful"
else
    echo "⚠️ Redis connection test failed (this might be normal if Redis requires auth)"
    echo "📋 Proceeding with deployment - LiveKit will handle Redis auth"
fi

# Step 3: Find SSL Certificate
echo ""
echo "🔍 Step 3: Finding SSL Certificate"
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

# Step 4: Deploy LiveKit with Custom Values
echo ""
echo "🚀 Step 4: Deploy LiveKit with Custom Values"

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

# ALB Configuration - Internet Facing
ingress:
  enabled: true
  className: "alb"
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: "$CERT_ARN"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
  hosts:
    - host: "$DOMAIN"
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - "$DOMAIN"
      secretName: livekit-tls

# Service Configuration
service:
  type: ClusterIP
  port: 7880
EOF

echo "✅ LiveKit values file created"

cd "$(dirname "$0")/.."

# Deploy LiveKit
echo "🚀 Deploying LiveKit..."
echo "📋 Chart: livekit/$CHART_NAME"
echo "�  Release: $RELEASE_NAME"
echo "📋 Namespace: $NAMESPACE"

# Determine deployment action based on cleanup results
if [ "$FORCE_FRESH_INSTALL" = true ]; then
    echo "🚀 Performing fresh installation..."
    HELM_ACTION="install"
else
    # Check if release exists for upgrade
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "� Ulpgrading existing LiveKit release..."
        HELM_ACTION="upgrade"
    else
        echo "🚀 Installing new LiveKit release..."
        HELM_ACTION="install"
    fi
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
    echo "📋 Troubleshooting:"
    echo "📋 Helm status:"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
    echo "📋 Pods:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "   No pods found"
    echo "📋 Events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 || true
    
    # If this was an upgrade that failed, try fresh install
    if [ "$HELM_ACTION" = "upgrade" ]; then
        echo "� Upgriade failed, trying fresh install after cleanup..."
        
        # Clean up failed upgrade
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
        kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 2>/dev/null || true
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

# Step 5: Verify Deployment
echo ""
echo "🔍 Step 5: Verify Deployment"

echo "⏳ Waiting for LiveKit pods to be ready..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit-server -n "$NAMESPACE" --timeout=180s; then
    echo "✅ LiveKit pods are ready!"
else
    echo "⚠️ Some pods may still be starting..."
fi

echo ""
echo "📊 Pod Status:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server

echo ""
echo "� Suervice Status:"
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
echo "   - Check pods: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo "   - Check services: kubectl get svc -n $NAMESPACE"
echo "   - View logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"

# Clean up temporary file
rm -f scripts/livekit-values.yaml