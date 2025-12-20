#!/bin/bash

# LiveKit Deployment Script
# Deploys LiveKit on EKS with proper AWS Load Balancer integration
# Follows LiveKit official documentation and AWS best practices

set -e

echo "🎥 Deploying LiveKit on EKS..."
echo "📋 Following LiveKit official documentation"
echo "🔗 Reference: https://docs.livekit.io/deploy/kubernetes/"

# Check if required environment variables are provided
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name REDIS_ENDPOINT=your-redis-endpoint ./03-deploy-livekit.sh"
    exit 1
fi

if [ -z "$REDIS_ENDPOINT" ]; then
    echo "❌ REDIS_ENDPOINT environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name REDIS_ENDPOINT=your-redis-endpoint ./03-deploy-livekit.sh"
    exit 1
fi

# Set AWS region (default to us-east-1 if not set)
AWS_REGION=${AWS_REGION:-us-east-1}

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region:  $AWS_REGION"
echo "   Redis:   $REDIS_ENDPOINT"
echo "   Documentation: LiveKit Kubernetes Deployment Guide"

# Verify AWS Load Balancer Controller is installed
echo "🔍 Verifying AWS Load Balancer Controller is installed..."
if ! kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
    echo "❌ AWS Load Balancer Controller not found"
    echo "💡 Please run the load balancer setup script first: ./02-setup-load-balancer.sh"
    exit 1
fi

LB_CONTROLLER_STATUS=$(kubectl get deployment -n kube-system aws-load-balancer-controller --no-headers | awk '{print $2}')
echo "📋 Load Balancer Controller status: $LB_CONTROLLER_STATUS"

if [[ "$LB_CONTROLLER_STATUS" != *"/"* ]] || [[ "${LB_CONTROLLER_STATUS%/*}" != "${LB_CONTROLLER_STATUS#*/}" ]]; then
    READY=$(echo "$LB_CONTROLLER_STATUS" | cut -d'/' -f1)
    DESIRED=$(echo "$LB_CONTROLLER_STATUS" | cut -d'/' -f2)
    
    if [ "$READY" != "$DESIRED" ] || [ "$READY" = "0" ]; then
        echo "❌ AWS Load Balancer Controller is not ready ($LB_CONTROLLER_STATUS)"
        echo "💡 Please ensure the load balancer controller is running before deploying LiveKit"
        exit 1
    fi
fi
echo "✅ AWS Load Balancer Controller is ready"

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"; then
    echo "❌ Failed to update kubeconfig"
    exit 1
fi

# Test kubectl connectivity
echo "🔍 Testing kubectl connectivity..."
if ! timeout 30 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cluster is not accessible via kubectl"
    exit 1
fi
echo "✅ Cluster is accessible"

# Get cluster information for LoadBalancer configuration
echo "🔍 Getting cluster information for LoadBalancer configuration..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNET_IDS"

# Create or use existing namespace
NAMESPACE="livekit"
echo "📦 Setting up namespace: $NAMESPACE"

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$NAMESPACE' already exists"
    
    # Check if there's already a LiveKit deployment
    if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=livekit >/dev/null 2>&1; then
        echo "⚠️ Existing LiveKit deployment found in '$NAMESPACE'"
        
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
                echo "⚠️ Existing deployment is unhealthy ($EXISTING_STATUS)"
                echo "🔄 Will replace with new deployment"
                UPGRADE_EXISTING=false
            fi
        else
            echo "⚠️ No deployment found despite namespace existing"
            UPGRADE_EXISTING=false
        fi
    else
        echo "✅ Namespace exists but no LiveKit deployment found"
        UPGRADE_EXISTING=false
    fi
else
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
    UPGRADE_EXISTING=false
fi

# Add LiveKit Helm repository
echo "📦 Setting up LiveKit Helm repository..."
if helm repo list | grep -q "^livekit\s"; then
    echo "✅ LiveKit repository already exists"
else
    if helm repo add livekit https://helm.livekit.io/; then
        echo "✅ LiveKit repository added successfully"
    else
        echo "❌ Failed to add LiveKit repository"
        exit 1
    fi
fi

echo "🔄 Updating Helm repositories..."
if helm repo update; then
    echo "✅ Helm repositories updated successfully"
else
    echo "❌ Failed to update Helm repositories"
    exit 1
fi

# Create LiveKit configuration
echo "🔧 Creating LiveKit configuration..."
cd "$(dirname "$0")/.."

# Generate API key and secret if not provided
API_KEY=${LIVEKIT_API_KEY:-"devkey"}
API_SECRET=${LIVEKIT_API_SECRET:-"devsecret"}

cat > livekit-values-production.yaml << EOF
# LiveKit Production Configuration
# Based on official LiveKit Kubernetes deployment guide

livekit:
  # Domain configuration - update this to your actual domain
  domain: "livekit.digi-telephony.com"
  
  # RTC configuration optimized for AWS
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
    tcp_fallback_port: 443
    
  # Redis configuration
  redis:
    address: "$REDIS_ENDPOINT"
    
  # API keys - use secure keys in production
  keys:
    $API_KEY: $API_SECRET
    
  # Logging configuration
  log_level: info
  
  # Resource configuration
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
      
  # High availability configuration
  replicaCount: 2
  
  # Pod disruption budget
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
    
  # Pod anti-affinity for better distribution
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
                    - livekit
            topologyKey: "kubernetes.io/hostname"

# Service configuration for AWS Load Balancer
service:
  type: LoadBalancer
  annotations:
    # Use AWS Load Balancer Controller
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-subnets: "$SUBNET_IDS"
    # Health check configuration
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "HTTP"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/health"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "7880"
    # Performance optimizations
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "tcp"
  ports:
    - name: http
      port: 7880
      targetPort: 7880
      protocol: TCP
    - name: rtc-tcp
      port: 7881
      targetPort: 7881
      protocol: TCP

# Ingress configuration for HTTP/WebSocket traffic
ingress:
  enabled: true
  className: "alb"
  annotations:
    # AWS ALB Ingress Controller annotations
    kubernetes.io/ingress.class: "alb"
    alb.ingress.kubernetes.io/scheme: "internet-facing"
    alb.ingress.kubernetes.io/target-type: "ip"
    alb.ingress.kubernetes.io/subnets: "$SUBNET_IDS"
    # SSL configuration - update certificate ARN for your domain
    alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:us-east-1:918595516608:certificate/388e3ff7-9763-4772-bfef-56cf64fcc414"
    alb.ingress.kubernetes.io/ssl-policy: "ELBSecurityPolicy-TLS-1-2-2017-01"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    # Health check configuration
    alb.ingress.kubernetes.io/healthcheck-path: "/health"
    alb.ingress.kubernetes.io/healthcheck-protocol: "HTTP"
    alb.ingress.kubernetes.io/healthcheck-port: "7880"
    # Performance optimizations
    alb.ingress.kubernetes.io/load-balancer-attributes: "idle_timeout.timeout_seconds=60"
  hosts:
    - host: livekit.digi-telephony.com
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: livekit
              port:
                number: 7880
  tls:
    - hosts:
        - livekit.digi-telephony.com

# Monitoring and metrics
metrics:
  enabled: true
  serviceMonitor:
    enabled: false  # Enable if you have Prometheus operator

# Additional configuration for production
nodeSelector: {}
tolerations: []

# Security context
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000

EOF

# Deploy or upgrade LiveKit
RELEASE_NAME="livekit"
CHART_VERSION="1.5.2"  # Use stable version

if [ "$UPGRADE_EXISTING" = true ]; then
    echo "🔄 Upgrading existing LiveKit deployment..."
    HELM_ACTION="upgrade"
else
    echo "🚀 Installing new LiveKit deployment..."
    HELM_ACTION="install"
fi

echo "📋 Deployment configuration:"
echo "   - Action: $HELM_ACTION"
echo "   - Release: $RELEASE_NAME"
echo "   - Chart Version: $CHART_VERSION"
echo "   - Namespace: $NAMESPACE"
echo "   - Domain: livekit.digi-telephony.com"
echo "   - Redis: $REDIS_ENDPOINT"
echo "   - API Key: $API_KEY"

echo "⏳ Starting Helm $HELM_ACTION (timeout: 15 minutes)..."

if helm "$HELM_ACTION" "$RELEASE_NAME" livekit/livekit \
    -n "$NAMESPACE" \
    -f livekit-values-production.yaml \
    --version "$CHART_VERSION" \
    --wait --timeout=15m; then
    
    echo "✅ LiveKit $HELM_ACTION completed successfully!"
else
    echo "❌ LiveKit $HELM_ACTION failed"
    
    echo "📋 Troubleshooting information:"
    echo "   Helm release status:"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Release not found"
    
    echo "   Deployments:"
    kubectl get deployment -n "$NAMESPACE" || echo "   No deployments found"
    
    echo "   Pods:"
    kubectl get pods -n "$NAMESPACE" || echo "   No pods found"
    
    echo "   Services:"
    kubectl get svc -n "$NAMESPACE" || echo "   No services found"
    
    echo "   Recent events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10
    
    exit 1
fi

# Wait for pods to be ready
echo "⏳ Waiting for LiveKit pods to be ready (timeout: 5 minutes)..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=livekit -n "$NAMESPACE" --timeout=300s; then
    echo "✅ LiveKit pods are ready!"
else
    echo "⚠️ Some pods may not be ready yet"
    
    echo "📋 Current pod status:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit
    
    echo "📋 Pod logs (last 20 lines):"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --tail=20
fi

# Get deployment status
echo ""
echo "📊 Deployment Status:"
kubectl get all -n "$NAMESPACE"

# Get LoadBalancer endpoints
echo ""
echo "🌐 Getting LoadBalancer endpoints..."

# Check ALB Ingress
echo "📋 Checking ALB Ingress..."
ALB_ADDRESS=""
for i in {1..12}; do  # Wait up to 2 minutes
    ALB_ADDRESS=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_ADDRESS" ]; then
        break
    fi
    echo "   Attempt $i/12: ALB still provisioning..."
    sleep 10
done

if [ -n "$ALB_ADDRESS" ]; then
    echo "✅ ALB Ingress: https://$ALB_ADDRESS"
    echo "✅ LiveKit WebSocket: wss://$ALB_ADDRESS"
else
    echo "⏳ ALB Ingress is still being provisioned (this can take 5-10 minutes)"
    echo "💡 Check status with: kubectl get ingress -n $NAMESPACE"
fi

# Check NLB Service
echo "📋 Checking NLB for RTC traffic..."
NLB_ADDRESS=""
for i in {1..12}; do  # Wait up to 2 minutes
    NLB_ADDRESS=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$NLB_ADDRESS" ]; then
        break
    fi
    echo "   Attempt $i/12: NLB still provisioning..."
    sleep 10
done

if [ -n "$NLB_ADDRESS" ]; then
    echo "✅ RTC LoadBalancer: $NLB_ADDRESS"
else
    echo "⏳ RTC LoadBalancer is still being provisioned (this can take 5-10 minutes)"
    echo "💡 Check status with: kubectl get svc -n $NAMESPACE"
fi

# Show LiveKit configuration
echo ""
echo "📋 LiveKit Configuration:"
echo "   API Endpoint: https://livekit.digi-telephony.com"
echo "   WebSocket URL: wss://livekit.digi-telephony.com"
echo "   API Key: $API_KEY"
echo "   API Secret: $API_SECRET"

# Test LiveKit health endpoint
echo ""
echo "🔍 Testing LiveKit health endpoint..."
if [ -n "$ALB_ADDRESS" ]; then
    echo "⏳ Waiting for ALB to be fully ready (30 seconds)..."
    sleep 30
    
    if curl -s --connect-timeout 10 "https://$ALB_ADDRESS/health" >/dev/null 2>&1; then
        echo "✅ LiveKit health endpoint is responding!"
        
        # Test the actual health response
        HEALTH_RESPONSE=$(curl -s --connect-timeout 10 "https://$ALB_ADDRESS/health" || echo "")
        if [ -n "$HEALTH_RESPONSE" ]; then
            echo "📋 Health response: $HEALTH_RESPONSE"
        fi
    else
        echo "⚠️ Health endpoint not responding yet (this is normal during initial deployment)"
        echo "💡 The service may still be starting up"
    fi
else
    echo "⏳ Skipping health check - ALB not ready yet"
fi

# Clean up temporary files
rm -f livekit-values-production.yaml

echo ""
echo "🎉 LiveKit deployment completed successfully!"
echo ""
echo "📋 Deployment Summary:"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ Release: $RELEASE_NAME"
echo "   ✅ Chart Version: $CHART_VERSION"
echo "   ✅ Cluster: $CLUSTER_NAME"
echo "   ✅ Redis: $REDIS_ENDPOINT"
echo "   ✅ Domain: livekit.digi-telephony.com"
echo ""
echo "📋 Next Steps:"
echo "   1. Wait for LoadBalancers to get external endpoints (5-10 minutes)"
echo "      kubectl get svc -n $NAMESPACE"
echo "      kubectl get ingress -n $NAMESPACE"
echo "   2. Configure DNS to point livekit.digi-telephony.com to the ALB endpoint"
echo "   3. Test LiveKit connection using the WebSocket URL"
echo "   4. Monitor deployment: kubectl get pods -n $NAMESPACE"
echo ""
echo "📋 Useful Commands:"
echo "   - Check pods: kubectl get pods -n $NAMESPACE"
echo "   - Check services: kubectl get svc -n $NAMESPACE"
echo "   - Check ingress: kubectl get ingress -n $NAMESPACE"
echo "   - View logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit"
echo "   - Port forward for testing: kubectl port-forward -n $NAMESPACE svc/livekit 7880:7880"
echo ""
echo "🔧 LoadBalancer provisioning may take 5-10 minutes to complete"
echo "📖 Documentation: https://docs.livekit.io/deploy/kubernetes/"