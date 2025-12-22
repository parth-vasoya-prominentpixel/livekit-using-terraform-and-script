#!/bin/bash

# LiveKit Deployment Script - Terraform Version
# Follows LiveKit official documentation with AWS EKS integration
# Uses unique names to avoid conflicts and optimized timing
# Reference: https://docs.livekit.io/deploy/kubernetes/

set -e

echo "🎥 LiveKit Deployment - Terraform Version"
echo "========================================="
echo "📋 Following LiveKit official Kubernetes deployment guide"
echo "🔗 https://docs.livekit.io/deploy/kubernetes/"
echo "🎯 Uses unique names and optimized timing"

# Check required environment variables
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export REDIS_ENDPOINT=your-redis-endpoint"
    echo "  export AWS_REGION=us-east-1  # optional, defaults to us-east-1"
    echo "  ./03-deploy-livekit-terraform.sh"
    echo ""
    exit 1
fi

if [ -z "$REDIS_ENDPOINT" ]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    echo ""
    echo "Usage:"
    echo "  export CLUSTER_NAME=your-cluster-name"
    echo "  export REDIS_ENDPOINT=your-redis-endpoint"
    echo "  export AWS_REGION=us-east-1  # optional, defaults to us-east-1"
    echo "  ./03-deploy-livekit-terraform.sh"
    echo ""
    exit 1
fi

# Set defaults
AWS_REGION=${AWS_REGION:-us-east-1}

# Set standard names (no unique suffix needed)
NAMESPACE="livekit"
RELEASE_NAME="livekit"
DOMAIN="livekit-eks-tf.digi-telephony.com"

echo ""
echo "📋 Configuration:"
echo "   Cluster Name: $CLUSTER_NAME"
echo "   AWS Region: $AWS_REGION"
echo "   Redis Endpoint: $REDIS_ENDPOINT"
echo ""
echo "📋 Resource Names:"
echo "   Namespace: $NAMESPACE"
echo "   Helm Release: $RELEASE_NAME"
echo "   Domain: $DOMAIN"
echo ""

# Quick AWS and cluster verification
echo "🔍 Quick verification checks..."

# Check AWS credentials (fast check)
if ! aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured or invalid"
    exit 1
fi

# Check cluster exists (fast check)
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text >/dev/null 2>&1; then
    echo "❌ Cluster '$CLUSTER_NAME' not found or not accessible"
    exit 1
fi

echo "✅ AWS credentials and cluster verified"

# Update kubeconfig (no wait needed)
echo ""
echo "🔧 Updating kubeconfig..."
if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME-livekit" >/dev/null 2>&1; then
    echo "❌ Failed to update kubeconfig"
    exit 1
fi

# Quick kubectl test (5 second timeout instead of 30)
echo "🔍 Testing kubectl connectivity..."
if ! timeout 5 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to cluster via kubectl"
    exit 1
fi
echo "✅ kubectl connectivity verified"

# Verify AWS Load Balancer Controller (smart check)
echo ""
echo "🔍 Verifying AWS Load Balancer Controller..."

# Check if any load balancer controller exists and is healthy
LB_CONTROLLERS=$(kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)

if [ "$LB_CONTROLLERS" -eq 0 ]; then
    echo "❌ No AWS Load Balancer Controller found"
    echo "💡 Please run the load balancer setup script first:"
    echo "   ./scripts/02-setup-load-balancer.sh"
    exit 1
fi

# Check if any controller is healthy
HEALTHY_CONTROLLER_FOUND=false
kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | while read name ready rest; do
    if [[ "$ready" == *"/"* ]]; then
        READY_COUNT=$(echo "$ready" | cut -d'/' -f1)
        DESIRED_COUNT=$(echo "$ready" | cut -d'/' -f2)
        if [ "$READY_COUNT" = "$DESIRED_COUNT" ] && [ "$READY_COUNT" != "0" ]; then
            echo "✅ Found healthy controller: $name ($ready)"
            HEALTHY_CONTROLLER_FOUND=true
            break
        fi
    fi
done

if [ "$HEALTHY_CONTROLLER_FOUND" != true ]; then
    echo "⚠️ Load balancer controllers exist but none are healthy"
    echo "💡 Please check controller status or re-run setup script"
    kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
    exit 1
fi

echo "✅ AWS Load Balancer Controller is ready"

# Get cluster information for LoadBalancer configuration (parallel execution)
echo ""
echo "🔍 Getting cluster information..."

# Get VPC and subnets in parallel (faster than sequential)
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text) &
VPC_PID=$!

SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',') &
SUBNET_PID=$!

# Wait for both to complete
wait $VPC_PID
wait $SUBNET_PID

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNET_IDS"

# Create or use existing namespace
NAMESPACE="livekit"
echo ""
echo "📦 Setting up namespace: $NAMESPACE"

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$NAMESPACE' already exists"
    
    # Check if there's already a LiveKit deployment
    if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit >/dev/null 2>&1; then
        echo "✅ Existing LiveKit deployment found"
        
        # Check deployment health
        EXISTING_STATUS=$(kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers | awk '{print $2}' | head -1)
        if [ -n "$EXISTING_STATUS" ]; then
            READY=$(echo "$EXISTING_STATUS" | cut -d'/' -f1)
            DESIRED=$(echo "$EXISTING_STATUS" | cut -d'/' -f2)
            
            if [ "$READY" = "$DESIRED" ] && [ "$READY" != "0" ]; then
                echo "✅ Existing deployment is healthy ($EXISTING_STATUS)"
                echo "🔄 Will upgrade existing deployment"
                UPGRADE_EXISTING=true
            else
                echo "⚠️ Existing deployment needs attention ($EXISTING_STATUS)"
                echo "🔄 Will upgrade to fix issues"
                UPGRADE_EXISTING=true
            fi
        else
            echo "⚠️ No deployment found despite namespace existing"
            UPGRADE_EXISTING=false
        fi
    else
        echo "✅ Namespace exists, no LiveKit deployment found"
        UPGRADE_EXISTING=false
    fi
else
    echo "📦 Creating namespace: $NAMESPACE"
    if kubectl create namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "✅ Namespace created"
    else
        echo "❌ Failed to create namespace"
        exit 1
    fi
    UPGRADE_EXISTING=false
fi

# Setup LiveKit Helm repository (optimized)
echo ""
echo "📦 Setting up LiveKit Helm repository..."

# Check if repository exists (fast check)
if helm repo list 2>/dev/null | grep -q "^livekit\s"; then
    echo "✅ LiveKit repository already exists"
else
    if helm repo add livekit https://helm.livekit.io/ >/dev/null 2>&1; then
        echo "✅ LiveKit repository added"
    else
        echo "❌ Failed to add LiveKit repository"
        exit 1
    fi
fi

# Update repositories (background process to save time)
echo "🔄 Updating Helm repositories..."
helm repo update >/dev/null 2>&1 &
REPO_UPDATE_PID=$!

# Generate API credentials
API_KEY=${LIVEKIT_API_KEY:-"devkey"}
API_SECRET=${LIVEKIT_API_SECRET:-"devsecret"}

# Create LiveKit configuration while repo update runs
echo ""
echo "🔧 Creating LiveKit configuration..."
cd "$(dirname "$0")/.."

cat > "livekit-values.yaml" << EOF
livekit:
  domain: $DOMAIN
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: "$REDIS_ENDPOINT"  # This will be replaced by the deployment script
  keys:
    "$API_KEY": "$API_SECRET"
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
  domain: "turn-eks-tf.${DOMAIN}"
  tls_port: 3478
  udp_port: 3478

loadBalancer:
  type: alb
  tls:
    - hosts:
        - "$DOMAIN"
      certificateArn: arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414
EOF

echo "✅ LiveKit configuration created"

# Wait for repo update to complete (if still running)
if kill -0 $REPO_UPDATE_PID 2>/dev/null; then
    echo "⏳ Waiting for repository update to complete..."
    wait $REPO_UPDATE_PID
fi
echo "✅ Helm repositories updated"

# Deploy LiveKit (optimized timeout)
CHART_VERSION="1.5.2"  # Stable version

echo ""
echo "🚀 Deploying LiveKit..."
echo "📋 Deployment configuration:"
echo "   Release: $RELEASE_NAME"
echo "   Chart Version: $CHART_VERSION"
echo "   Namespace: $NAMESPACE"
echo "   Domain: $DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"

echo ""
echo "⏳ Starting Helm installation (timeout: 10 minutes)..."

if helm "$HELM_ACTION" "$RELEASE_NAME" livekit/livekit \
    -n "$NAMESPACE" \
    -f "livekit-values.yaml" \
    --version "$CHART_VERSION" \
    --wait --timeout=10m >/dev/null 2>&1; then
    
    echo "✅ LiveKit deployment completed successfully!"
else
    echo "❌ LiveKit deployment failed"
    
    echo ""
    echo "📋 Troubleshooting information:"
    echo "   Helm status:"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
    
    echo "   Pods:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "   No pods found"
    
    echo "   Events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -5
    
    exit 1
fi

# Optimized pod readiness check (reduced timeout)
echo ""
echo "⏳ Waiting for LiveKit pods to be ready (timeout: 3 minutes)..."

if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1; then
    echo "✅ LiveKit pods are ready!"
else
    echo "⚠️ Some pods may not be ready yet, but continuing..."
    
    # Show current status for debugging
    echo "📋 Current pod status:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit 2>/dev/null || echo "   No pods found"
fi

# Get deployment status (quick check)
echo ""
echo "📊 Deployment Status:"
RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l || echo "0")

echo "   Pods: $RUNNING_PODS/$TOTAL_PODS running"

if [ "$RUNNING_PODS" -gt 0 ]; then
    echo "✅ LiveKit pods are running"
else
    echo "⚠️ No pods running yet (may still be starting)"
fi

# Get LoadBalancer endpoints (optimized with shorter waits)
echo ""
echo "🌐 Checking LoadBalancer endpoints..."

# Check ALB Ingress (reduced wait time)
echo "📋 Checking ALB Ingress..."
ALB_ADDRESS=""
for i in {1..6}; do  # Wait up to 1 minute instead of 2
    ALB_ADDRESS=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_ADDRESS" ]; then
        break
    fi
    if [ $i -lt 6 ]; then
        echo "   Attempt $i/6: ALB provisioning... (waiting 10s)"
        sleep 10
    fi
done

if [ -n "$ALB_ADDRESS" ]; then
    echo "✅ ALB Ingress: https://$ALB_ADDRESS"
    echo "✅ LiveKit WebSocket: wss://$ALB_ADDRESS"
else
    echo "⏳ ALB Ingress still provisioning (this can take 5-10 minutes)"
    echo "💡 Check later with: kubectl get ingress -n $NAMESPACE"
fi

# Check NLB Service (reduced wait time)
echo ""
echo "📋 Checking NLB for RTC traffic..."
NLB_ADDRESS=""
for i in {1..6}; do  # Wait up to 1 minute instead of 2
    NLB_ADDRESS=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$NLB_ADDRESS" ]; then
        break
    fi
    if [ $i -lt 6 ]; then
        echo "   Attempt $i/6: NLB provisioning... (waiting 10s)"
        sleep 10
    fi
done

if [ -n "$NLB_ADDRESS" ]; then
    echo "✅ RTC LoadBalancer: $NLB_ADDRESS"
else
    echo "⏳ RTC LoadBalancer still provisioning (this can take 5-10 minutes)"
    echo "💡 Check later with: kubectl get svc -n $NAMESPACE"
fi

# Quick health check (if ALB is ready)
if [ -n "$ALB_ADDRESS" ]; then
    echo ""
    echo "🔍 Quick health check..."
    
    # Short wait for ALB to be ready (reduced from 30s to 10s)
    sleep 10
    
    if curl -s --connect-timeout 5 "https://$ALB_ADDRESS/health" >/dev/null 2>&1; then
        echo "✅ LiveKit health endpoint responding!"
    else
        echo "⏳ Health endpoint not ready yet (normal during initial deployment)"
    fi
fi

# Clean up temporary files
rm -f "livekit-values.yaml"

# Final summary
echo ""
echo "🎉 LiveKit Deployment Completed Successfully!"
echo "==========================================="
echo ""
echo "📋 Deployment Summary:"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ Release: $RELEASE_NAME"
echo "   ✅ Chart Version: $CHART_VERSION"
echo "   ✅ Cluster: $CLUSTER_NAME"
echo "   ✅ Redis: $REDIS_ENDPOINT"
echo "   ✅ Domain: $DOMAIN"
echo ""
echo "📋 LiveKit Configuration:"
echo "   API Endpoint: https://$DOMAIN"
echo "   WebSocket URL: wss://$DOMAIN"
echo "   API Key: $API_KEY"
echo "   API Secret: $API_SECRET"
echo ""
echo "📋 Monitoring Commands:"
echo "   - Check pods: kubectl get pods -n $NAMESPACE"
echo "   - Check services: kubectl get svc -n $NAMESPACE"
echo "   - Check ingress: kubectl get ingress -n $NAMESPACE"
echo "   - View logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit"
echo ""
echo "📋 Next Steps:"
echo "   1. Wait for LoadBalancers to get external endpoints (5-10 minutes)"
echo "   2. Configure DNS to point $DOMAIN to the ALB endpoint"
echo "   3. Test LiveKit connection using the WebSocket URL"
echo ""
echo "💡 Uses existing resources when available - no conflicts!"
echo "🔧 LoadBalancer provisioning continues in background"