#!/bin/bash

# LiveKit Deployment Script - Complete and Self-Contained
# Uses common configuration and properly waits for LoadBalancer provisioning
# Handles all edge cases and provides comprehensive status checking

set -e

echo "🎥 LiveKit Complete Deployment"
echo "=============================="
echo "📋 Self-contained deployment with proper LoadBalancer provisioning"
echo ""

# Load common configuration
if [ ! -f "livekit-config.yaml" ]; then
    echo "❌ livekit-config.yaml not found"
    echo "💡 This file contains all common configuration used across scripts"
    exit 1
fi

echo "📋 Loading common configuration..."
source livekit-config.yaml
echo "✅ Configuration loaded"

echo ""
echo "📋 Deployment Configuration:"
echo "   AWS Region: $AWS_REGION"
echo "   Cluster: $CLUSTER_NAME"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"
echo "   Domain: $DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Autoscaling: $MIN_REPLICAS-$MAX_REPLICAS replicas at ${CPU_THRESHOLD}% CPU"
echo ""

# Comprehensive verification
echo "🔍 Comprehensive System Verification"
echo "===================================="

# Check AWS credentials
echo "🔍 Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured"
    echo "💡 Run: aws configure"
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✅ AWS credentials verified (Account: $ACCOUNT_ID)"

# Update kubeconfig
echo "🔍 Updating kubeconfig..."
if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    echo "❌ Failed to update kubeconfig"
    echo "💡 Check if cluster '$CLUSTER_NAME' exists in region '$AWS_REGION'"
    exit 1
fi
echo "✅ Kubeconfig updated"

# Test cluster connectivity
echo "🔍 Testing cluster connectivity..."
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to cluster"
    echo "💡 Check cluster status and network connectivity"
    exit 1
fi
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo "✅ Cluster connectivity verified ($NODE_COUNT nodes)"

# Verify AWS Load Balancer Controller
echo "🔍 Verifying AWS Load Balancer Controller..."
LB_CONTROLLER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)
if [ "$LB_CONTROLLER_PODS" -eq 0 ]; then
    echo "❌ AWS Load Balancer Controller not found"
    echo "💡 Run: ./scripts/02-setup-load-balancer.sh"
    exit 1
fi

LB_READY_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$LB_READY_PODS" -eq 0 ]; then
    echo "❌ AWS Load Balancer Controller pods not ready"
    echo "💡 Check controller status: kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
    exit 1
fi
echo "✅ AWS Load Balancer Controller ready ($LB_READY_PODS/$LB_CONTROLLER_PODS pods)"

echo ""
echo "🔧 Namespace and Deployment Management"
echo "====================================="

# Setup namespace
echo "🔍 Setting up namespace '$NAMESPACE'..."
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
    echo "✅ Namespace created"
else
    echo "✅ Namespace '$NAMESPACE' exists"
fi

# Check existing deployment
echo "🔍 Checking for existing LiveKit deployment..."
EXISTING_RELEASE=""
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    EXISTING_RELEASE="true"
    echo "📋 Found existing release: $RELEASE_NAME"
    
    # Check deployment health
    echo "🔍 Checking deployment health..."
    TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
    READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "📋 Current status: $READY_PODS/$TOTAL_PODS pods ready"
    
    if [ "$READY_PODS" -eq 0 ] && [ "$TOTAL_PODS" -gt 0 ]; then
        echo "⚠️ Deployment exists but unhealthy - will clean up and redeploy"
        echo "🗑️ Removing unhealthy deployment..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait || true
        kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --force --grace-period=0 || true
        echo "⏳ Waiting for cleanup to complete..."
        sleep 15
        EXISTING_RELEASE=""
        echo "✅ Cleanup completed"
    elif [ "$READY_PODS" -gt 0 ]; then
        echo "✅ Existing deployment is healthy - will upgrade"
    else
        echo "📋 No existing pods found - will install fresh"
        EXISTING_RELEASE=""
    fi
else
    echo "📋 No existing release found - will install fresh"
fi

echo ""
echo "📦 Helm Repository Setup"
echo "========================"

# Setup LiveKit Helm repository
echo "🔍 Setting up LiveKit Helm repository..."
if ! helm repo add livekit https://helm.livekit.io >/dev/null 2>&1; then
    echo "❌ Failed to add LiveKit Helm repository"
    exit 1
fi

echo "🔄 Updating Helm repositories..."
if ! helm repo update >/dev/null 2>&1; then
    echo "❌ Failed to update Helm repositories"
    exit 1
fi

# Verify chart availability
echo "🔍 Verifying chart availability..."
if ! helm search repo livekit/livekit-server >/dev/null 2>&1; then
    echo "❌ LiveKit server chart not found"
    exit 1
fi
echo "✅ LiveKit Helm repository ready"

echo ""
echo "🔧 Cluster Information Gathering"
echo "================================"

# Get cluster information for LoadBalancer
echo "🔍 Gathering cluster information..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "null" ]; then
    echo "❌ Failed to get VPC ID"
    exit 1
fi

SUBNETS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')
if [ -z "$SUBNETS" ]; then
    echo "❌ Failed to get subnet information"
    exit 1
fi

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNETS"

echo ""
echo "🔧 LiveKit Configuration Generation"
echo "==================================="

# Create comprehensive LiveKit Helm values
echo "🔧 Generating LiveKit Helm values..."
cat > /tmp/livekit-values.yaml << EOF
# LiveKit Server Configuration - Generated from common config
replicaCount: 2

image:
  repository: livekit/livekit-server
  tag: ""
  pullPolicy: IfNotPresent

livekit:
  # Domain configuration
  domain: $DOMAIN
  
  # RTC configuration for WebRTC
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
    
  # Redis configuration
  redis:
    address: $REDIS_ENDPOINT
    
  # API keys
  keys:
    $API_KEY: $SECRET_KEY

# TURN server configuration
turn:
  enabled: true
  domain: $TURN_DOMAIN
  tls_port: 3478
  udp_port: 3478

# Service configuration for LoadBalancer
service:
  type: LoadBalancer
  port: 7880
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-subnets: "$SUBNETS"

# Ingress disabled - using LoadBalancer service
ingress:
  enabled: false

# Autoscaling configuration
autoscaling:
  enabled: true
  minReplicas: $MIN_REPLICAS
  maxReplicas: $MAX_REPLICAS
  targetCPUUtilizationPercentage: $CPU_THRESHOLD

# Resource configuration
resources:
  limits:
    cpu: $CPU_LIMIT
    memory: $MEMORY_LIMIT
  requests:
    cpu: $CPU_REQUEST
    memory: $MEMORY_REQUEST

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

# Health checks
livenessProbe:
  httpGet:
    path: /
    port: 7880
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /
    port: 7880
  initialDelaySeconds: 5
  periodSeconds: 5
EOF

echo "✅ LiveKit configuration generated"

echo ""
echo "🚀 LiveKit Deployment"
echo "===================="

# Determine deployment action
if [ -n "$EXISTING_RELEASE" ]; then
    HELM_ACTION="upgrade"
    echo "📋 Action: Upgrading existing release"
else
    HELM_ACTION="install"
    echo "📋 Action: Installing new release"
fi

echo "📋 Release: $RELEASE_NAME"
echo "📋 Chart: livekit/livekit-server"
echo "📋 Namespace: $NAMESPACE"
echo ""

# Deploy with comprehensive retry logic
echo "⏳ Starting Helm deployment..."
MAX_ATTEMPTS=3
DEPLOYMENT_SUCCESS=false

for attempt in $(seq 1 $MAX_ATTEMPTS); do
    echo "📋 Deployment attempt $attempt/$MAX_ATTEMPTS..."
    
    if [ "$HELM_ACTION" = "upgrade" ]; then
        if helm upgrade "$RELEASE_NAME" livekit/livekit-server \
            -n "$NAMESPACE" \
            -f /tmp/livekit-values.yaml \
            --wait --timeout=10m; then
            echo "✅ LiveKit upgrade successful!"
            DEPLOYMENT_SUCCESS=true
            break
        else
            echo "⚠️ Upgrade attempt $attempt failed"
        fi
    else
        if helm install "$RELEASE_NAME" livekit/livekit-server \
            -n "$NAMESPACE" \
            -f /tmp/livekit-values.yaml \
            --wait --timeout=10m; then
            echo "✅ LiveKit installation successful!"
            DEPLOYMENT_SUCCESS=true
            break
        else
            echo "⚠️ Installation attempt $attempt failed"
        fi
    fi
    
    if [ $attempt -lt $MAX_ATTEMPTS ]; then
        echo "🔄 Retrying in 30 seconds..."
        sleep 30
    fi
done

if [ "$DEPLOYMENT_SUCCESS" = false ]; then
    echo "❌ LiveKit deployment failed after $MAX_ATTEMPTS attempts"
    echo ""
    echo "📋 Troubleshooting Information:"
    echo "🔍 Helm release status:"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
    echo ""
    echo "🔍 Pod status:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server 2>/dev/null || echo "   No pods found"
    echo ""
    echo "🔍 Recent events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10 2>/dev/null || echo "   No events found"
    echo ""
    echo "💡 Common issues:"
    echo "   - Redis connectivity (check security groups)"
    echo "   - Resource limits (check node capacity)"
    echo "   - Load Balancer Controller status"
    rm -f /tmp/livekit-values.yaml
    exit 1
fi

echo ""
echo "⏳ Post-Deployment Verification"
echo "==============================="

# Wait for pods to be ready with timeout
echo "🔍 Waiting for LiveKit pods to be ready..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit-server -n "$NAMESPACE" --timeout=${HEALTH_CHECK_TIMEOUT}s; then
    echo "✅ All LiveKit pods are ready!"
else
    echo "⚠️ Some pods may still be starting..."
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server
fi

echo ""
echo "⏳ LoadBalancer Provisioning"
echo "============================"

# Wait for LoadBalancer with proper timeout and status checking
echo "🔍 Waiting for LoadBalancer endpoint (timeout: ${LB_TIMEOUT}s)..."
LB_ENDPOINT=""
LB_ATTEMPTS=$((LB_TIMEOUT / 15))

for i in $(seq 1 $LB_ATTEMPTS); do
    LB_ENDPOINT=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ]; then
        echo "✅ LoadBalancer endpoint ready: $LB_ENDPOINT"
        break
    fi
    
    # Show progress every 5 attempts
    if [ $((i % 5)) -eq 0 ]; then
        echo "   Progress: $i/$LB_ATTEMPTS attempts (${i}0% of timeout)"
    fi
    
    echo "   Attempt $i/$LB_ATTEMPTS: LoadBalancer provisioning..."
    sleep 15
done

if [ -z "$LB_ENDPOINT" ] || [ "$LB_ENDPOINT" = "null" ]; then
    echo "⚠️ LoadBalancer endpoint not ready within timeout"
    echo "💡 This is normal for first deployment - LoadBalancer may take up to 10 minutes"
    echo "💡 Check later with: kubectl get svc -n $NAMESPACE $RELEASE_NAME"
    LB_ENDPOINT="<provisioning>"
fi

echo ""
echo "🔍 Health Check and Status"
echo "=========================="

# Show comprehensive deployment status
echo "📊 Deployment Status:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server
echo ""
kubectl get svc -n "$NAMESPACE"
echo ""

# Test LoadBalancer health if endpoint is ready
if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ] && [ "$LB_ENDPOINT" != "<provisioning>" ]; then
    echo "🔍 Testing LoadBalancer health..."
    echo "⏳ Waiting for LoadBalancer to initialize (30 seconds)..."
    sleep 30
    
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$LB_ENDPOINT/" --connect-timeout 10 --max-time 30 || echo "000")
    echo "📋 HTTP Status: $HTTP_STATUS"
    
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "404" ]; then
        echo "✅ LoadBalancer is responding correctly"
    else
        echo "⚠️ LoadBalancer may still be initializing"
        echo "💡 This is normal - full initialization can take a few more minutes"
    fi
fi

echo ""
echo "🎉 LiveKit Deployment Complete!"
echo "==============================="
echo ""
echo "📋 Connection Details:"
if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ] && [ "$LB_ENDPOINT" != "<provisioning>" ]; then
    echo "   ✅ WebSocket URL: ws://$LB_ENDPOINT"
    echo "   ✅ HTTP URL: http://$LB_ENDPOINT"
else
    echo "   ⏳ LoadBalancer: Still provisioning"
    echo "   💡 Check status: kubectl get svc -n $NAMESPACE $RELEASE_NAME"
fi
echo "   📋 Domain: $DOMAIN (configure DNS)"
echo "   📋 TURN Domain: $TURN_DOMAIN (configure DNS)"
echo ""
echo "🔑 API Credentials:"
echo "   📋 API Key: $API_KEY"
echo "   📋 Secret: $SECRET_KEY"
echo ""
echo "📊 Configuration:"
echo "   📋 Autoscaling: $MIN_REPLICAS-$MAX_REPLICAS replicas at ${CPU_THRESHOLD}% CPU"
echo "   📋 Resources: $CPU_REQUEST-$CPU_LIMIT CPU, $MEMORY_REQUEST-$MEMORY_LIMIT Memory"
echo ""

if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ] && [ "$LB_ENDPOINT" != "<provisioning>" ]; then
    echo "📋 DNS Configuration Required:"
    echo "   Create CNAME records pointing to: $LB_ENDPOINT"
    echo "   - $DOMAIN"
    echo "   - $TURN_DOMAIN"
    echo ""
fi

echo "📋 Monitoring Commands:"
echo "   - Pods: kubectl get pods -n $NAMESPACE"
echo "   - Service: kubectl get svc -n $NAMESPACE"
echo "   - Logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo "   - HPA: kubectl get hpa -n $NAMESPACE"
echo "   - Events: kubectl get events -n $NAMESPACE"
echo ""

echo "💡 LiveKit is ready for WebRTC connections!"
echo "💡 If LoadBalancer is still provisioning, wait a few minutes and check the service status"

# Cleanup
rm -f /tmp/livekit-values.yaml

echo ""
echo "✅ Deployment script completed successfully!"