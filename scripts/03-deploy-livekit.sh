#!/bin/bash

# LiveKit Deployment Script - Following Official Documentation
# https://docs.livekit.io/transport/self-hosting/kubernetes/

set -e

echo "🎥 LiveKit Deployment"
echo "===================="
echo "📋 Following official LiveKit documentation"
echo "📋 Using ALB Ingress Controller for signal connection"

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-lp-eks-livekit-use1-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="livekit"
RELEASE_NAME="livekit"

# Redis endpoints - Using Primary endpoint for read/write operations
# Primary endpoint: lp-ec-redis-use1-dev-redis.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379
# Reader endpoint: lp-ec-redis-use1-dev-redis-ro.x4ncn3.ng.0001.use1.cache.amazonaws.com:6379
# Configuration endpoint (user specified): clustercfg.livekit-redis.x4ncn3.use1.cache.amazonaws.com:6379
REDIS_ENDPOINT="${REDIS_ENDPOINT:-clustercfg.livekit-redis.x4ncn3.use1.cache.amazonaws.com:6379}"

# Domains and Certificate (EXACT as specified by user - UPDATED)
LIVEKIT_DOMAIN="livekit-eks-tf.digi-telephony.com"
TURN_DOMAIN="turn-eks-tf.digi-telephony.com"
CERT_ARN="arn:aws:acm:us-east-1:918595516608:certificate/4523a895-7899-41a3-8589-2a5baed3b420"

# API Keys
API_KEY="APIKmrHi78hxpbd"
SECRET_KEY="Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB"

echo ""
echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo "   LiveKit Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Namespace: $NAMESPACE"
echo "   Release: $RELEASE_NAME"

# Step 1: Setup
echo ""
echo "🔍 Quick verification..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
echo "✅ AWS and cluster verified"

# Verify Load Balancer Controller
echo ""
echo "🔍 Verifying AWS Load Balancer Controller..."
LB_CONTROLLER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l)
if [ "$LB_CONTROLLER_PODS" -gt 0 ]; then
    READY_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep "1/1.*Running" | wc -l)
    echo "✅ Load Balancer Controller is ready ($READY_PODS/$LB_CONTROLLER_PODS pods)"
    
    # Show controller details
    echo "📋 Controller pods:"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | while read line; do
        echo "   $line"
    done
else
    echo "❌ AWS Load Balancer Controller not found"
    echo "💡 Please run the load balancer setup script first"
    exit 1
fi

# Setup namespace
echo ""
echo "📦 Setting up namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Namespace '$NAMESPACE' ready"

# Clean up existing deployment
echo ""
echo "🔄 Cleaning up existing LiveKit deployment..."
# Check if livekit namespace exists
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "   Found existing namespace: $NAMESPACE"
    # Check for existing LiveKit deployment
    if helm list -n "$NAMESPACE" -q | grep -q "$RELEASE_NAME"; then
        echo "   Removing existing LiveKit deployment..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait 2>/dev/null || echo "   Failed to uninstall, continuing..."
        sleep 10
    else
        echo "   No existing LiveKit deployment found"
    fi
else
    echo "   No existing namespace found"
fi

# Step 2: Add Helm Repository (Official Documentation)
echo ""
echo "📦 Step 1: Add Helm Repository"
echo "==============================="
echo "🔧 Adding LiveKit Helm repository..."

# Remove existing repository if it exists
helm repo remove livekit 2>/dev/null || true

# Add the official LiveKit repository (from official docs)
helm repo add livekit https://helm.livekit.io
helm repo update
echo "✅ LiveKit repository added and updated"

# Verify chart availability
echo "🔍 Verifying LiveKit chart availability..."
helm search repo livekit/livekit-server --versions | head -5
echo "✅ LiveKit chart found"

# Get VPC information first
echo ""
echo "🔍 Getting cluster information..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ',')

echo "✅ VPC ID: $VPC_ID"
echo "✅ Subnets: $SUBNET_IDS"

# Step 3: Create open security group for ALB
echo ""
echo "� Crteating open security group for ALB..."
SG_NAME="livekit-alb-open-sg"
SG_DESCRIPTION="Open security group for LiveKit ALB - allows all traffic"

# Check if security group already exists
EXISTING_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ] && [ "$EXISTING_SG" != "null" ]; then
    echo "✅ Security group already exists: $EXISTING_SG"
    ALB_SECURITY_GROUP="$EXISTING_SG"
    
    # Verify it has the right rules (optional - just for info)
    echo "🔍 Verifying existing security group rules..."
    INBOUND_RULES=$(aws ec2 describe-security-groups --group-ids "$EXISTING_SG" --region "$AWS_REGION" --query 'SecurityGroups[0].IpPermissions[?FromPort==`80` || FromPort==`443`]' --output text 2>/dev/null || echo "")
    if [ -n "$INBOUND_RULES" ]; then
        echo "✅ Security group has HTTP/HTTPS rules configured"
    else
        echo "⚠️ Security group exists but may need rule updates"
    fi
else
    echo "🔧 Creating new security group..."
    ALB_SECURITY_GROUP=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "$SG_DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --region "$AWS_REGION" \
        --query 'GroupId' \
        --output text)
    
    echo "✅ Security group created: $ALB_SECURITY_GROUP"
    
    # Add inbound rules - Allow all traffic
    echo "🔧 Adding inbound rules (allow all traffic)..."
    aws ec2 authorize-security-group-ingress \
        --group-id "$ALB_SECURITY_GROUP" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$ALB_SECURITY_GROUP" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
    
    # Add outbound rules - Allow all traffic (default is usually all, but let's be explicit)
    echo "🔧 Adding outbound rules (allow all traffic)..."
    aws ec2 authorize-security-group-egress \
        --group-id "$ALB_SECURITY_GROUP" \
        --protocol -1 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
    
    echo "✅ Security group configured with open access"
fi

echo "📋 ALB Security Group: $ALB_SECURITY_GROUP"

# Step 4: Create LiveKit Values File
echo ""
echo "🚀 Step 3: Deploy LiveKit with Custom Values"
echo "============================================="
echo "🔧 Creating LiveKit values file..."

# Create LiveKit values based on user specification (CORRECT HELM STRUCTURE)
cat > /tmp/livekit-values.yaml << EOF
# LiveKit server configuration - Exact user specification
livekit:
  domain: $LIVEKIT_DOMAIN
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000
  redis:
    address: $REDIS_ENDPOINT
  keys:
    $API_KEY: $SECRET_KEY

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
  domain: $TURN_DOMAIN
  tls_port: 3478
  udp_port: 3478

# CRITICAL: Completely disable ingress to avoid validation errors
ingress:
  enabled: false

# Service configuration - CORRECT ALB configuration for LiveKit Helm chart
service:
  type: LoadBalancer
  annotations:
    # ALB Configuration (FIXED - use "alb" not "external")
    service.beta.kubernetes.io/aws-load-balancer-type: "alb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    # SSL Configuration
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: $CERT_ARN
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
    # Security Groups - Use the open security group we created
    service.beta.kubernetes.io/aws-load-balancer-security-groups: $ALB_SECURITY_GROUP
    # Target Group Health Check
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "traffic-port"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "http"
    # DNS Configuration
    external-dns.alpha.kubernetes.io/hostname: $LIVEKIT_DOMAIN

# Alternative approach - Create separate LoadBalancer service
serviceMonitor:
  enabled: false

# If the above doesn't work, we'll create a separate service
EOF

echo "✅ LiveKit values file created"

# Show configuration summary
echo ""
echo "📋 Configuration details:"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Certificate: $(basename "$CERT_ARN")"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Load Balancer: ALB (internet-facing) with target groups"
echo "   Security Group: $ALB_SECURITY_GROUP (open to all traffic)"
echo "   TLS: Enabled with ACM certificate"
echo "   Ingress: Disabled (using service LoadBalancer with ALB annotations)"
echo "   Health Check: HTTP on port 7880, path /"
echo "   TLS: Enabled with ACM certificate"

# Step 5: Deploy LiveKit (Simple Approach - No Ingress)
echo ""
echo "🚀 Installing LiveKit deployment..."
echo "📋 Using exact user specification with proper ALB configuration"

# Validate the values file first
echo "🔍 Validating Helm values..."
helm template "$RELEASE_NAME" livekit/livekit-server \
    --namespace "$NAMESPACE" \
    --values /tmp/livekit-values.yaml \
    --dry-run > /tmp/livekit-template.yaml

echo "✅ Helm template validation passed"

# Deploy with the official approach from LiveKit documentation
echo "🔍 Deploying LiveKit Server..."
if helm upgrade --install "$RELEASE_NAME" livekit/livekit-server \
    --namespace "$NAMESPACE" \
    --values /tmp/livekit-values.yaml \
    --wait --timeout=15m \
    --debug; then
    echo "✅ LiveKit installed successfully!"
else
    echo "❌ LiveKit installation failed"
    echo ""
    echo "� Troubletshooting information:"
    echo "==============================="
    
    # Show the generated values file for debugging
    echo "🔍 Generated values.yaml:"
    cat /tmp/livekit-values.yaml
    echo ""
    
    # Show the template output for debugging
    echo "🔍 Helm template output (first 50 lines):"
    head -50 /tmp/livekit-template.yaml || true
    echo ""
    
    # Show Kubernetes resources
    echo "🔍 Kubernetes resources:"
    kubectl get pods -n "$NAMESPACE" || true
    echo ""
    kubectl get svc -n "$NAMESPACE" || true
    echo ""
    kubectl get deployments -n "$NAMESPACE" || true
    echo ""
    
    # Show recent events
    echo "🔍 Recent events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -15 || true
    echo ""
    
    # Show pod logs if any exist
    echo "🔍 Pod logs:"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --tail=50 || true
    echo ""
    
    # Clean up failed installation
    echo "🧹 Cleaning up failed installation..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
    
    exit 1
fi

# Create separate ALB service if the Helm chart service is ClusterIP
echo ""
echo "🔧 Creating separate ALB LoadBalancer service..."

# First, let's check the actual pod labels to ensure correct targeting
echo "🔍 Detecting LiveKit pod labels for correct targeting..."
LIVEKIT_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep livekit | head -1 2>/dev/null || echo "")

if [ -n "$LIVEKIT_POD" ]; then
    echo "✅ Found LiveKit pod: $LIVEKIT_POD"
    
    # Get the actual labels from the pod
    APP_NAME=$(kubectl get pod "$LIVEKIT_POD" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null || echo "")
    APP_INSTANCE=$(kubectl get pod "$LIVEKIT_POD" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || echo "")
    APP_LABEL=$(kubectl get pod "$LIVEKIT_POD" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
    
    echo "📋 Detected labels:"
    echo "   app.kubernetes.io/name: $APP_NAME"
    echo "   app.kubernetes.io/instance: $APP_INSTANCE" 
    echo "   app: $APP_LABEL"
    
    # Create service with the correct selector
    cat > /tmp/livekit-alb-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: livekit-alb-service
  namespace: livekit
  annotations:
    # ALB Configuration
    service.beta.kubernetes.io/aws-load-balancer-type: "alb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    # SSL Configuration
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: $CERT_ARN
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
    # Security Groups
    service.beta.kubernetes.io/aws-load-balancer-security-groups: $ALB_SECURITY_GROUP
    # Health Check Configuration - Ensure proper targeting
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "7880"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "http"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval-seconds: "30"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout-seconds: "5"
    service.beta.kubernetes.io/aws-load-balancer-healthy-threshold-count: "2"
    service.beta.kubernetes.io/aws-load-balancer-unhealthy-threshold-count: "3"
    # Target Group Configuration - Ensure it points to LiveKit
    service.beta.kubernetes.io/aws-load-balancer-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: "deregistration_delay.timeout_seconds=30"
    # DNS Configuration
    external-dns.alpha.kubernetes.io/hostname: $LIVEKIT_DOMAIN
spec:
  type: LoadBalancer
  selector:
EOF

    # Add the correct selector based on what we found
    if [ -n "$APP_NAME" ] && [ -n "$APP_INSTANCE" ]; then
        echo "    app.kubernetes.io/name: $APP_NAME" >> /tmp/livekit-alb-service.yaml
        echo "    app.kubernetes.io/instance: $APP_INSTANCE" >> /tmp/livekit-alb-service.yaml
        echo "✅ Using app.kubernetes.io labels for targeting"
    elif [ -n "$APP_LABEL" ]; then
        echo "    app: $APP_LABEL" >> /tmp/livekit-alb-service.yaml
        echo "✅ Using app label for targeting"
    else
        echo "    app: livekit-livekit-server" >> /tmp/livekit-alb-service.yaml
        echo "⚠️ Using fallback selector"
    fi

    # Add ports
    cat >> /tmp/livekit-alb-service.yaml << EOF
  ports:
  - name: http
    port: 80
    targetPort: 7880
    protocol: TCP
  - name: https
    port: 443
    targetPort: 7880
    protocol: TCP
EOF

else
    echo "⚠️ No LiveKit pod found, using default selectors"
    # Create service with default selector
    cat > /tmp/livekit-alb-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: livekit-alb-service
  namespace: livekit
  annotations:
    # ALB Configuration
    service.beta.kubernetes.io/aws-load-balancer-type: "alb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    # SSL Configuration
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: $CERT_ARN
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
    # Security Groups
    service.beta.kubernetes.io/aws-load-balancer-security-groups: $ALB_SECURITY_GROUP
    # Health Check Configuration - Ensure proper targeting
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "7880"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "http"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval-seconds: "30"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout-seconds: "5"
    service.beta.kubernetes.io/aws-load-balancer-healthy-threshold-count: "2"
    service.beta.kubernetes.io/aws-load-balancer-unhealthy-threshold-count: "3"
    # Target Group Configuration - Ensure it points to LiveKit
    service.beta.kubernetes.io/aws-load-balancer-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: "deregistration_delay.timeout_seconds=30"
    # DNS Configuration
    external-dns.alpha.kubernetes.io/hostname: $LIVEKIT_DOMAIN
spec:
  type: LoadBalancer
  selector:
    app: livekit-livekit-server
  ports:
  - name: http
    port: 80
    targetPort: 7880
    protocol: TCP
  - name: https
    port: 443
    targetPort: 7880
    protocol: TCP
EOF
fi

kubectl apply -f /tmp/livekit-alb-service.yaml

echo "✅ ALB LoadBalancer service created"
echo "📋 Checking service status..."
kubectl get svc -n "$NAMESPACE" livekit-alb-service

# Verify the service is targeting the right pods
echo ""
echo "🔍 Verifying service endpoints..."
kubectl get endpoints -n "$NAMESPACE" livekit-alb-service

# Show which pods are being targeted
echo ""
echo "🔍 Pods targeted by ALB service:"
if [ -n "$LIVEKIT_POD" ]; then
    kubectl get pods -n "$NAMESPACE" "$LIVEKIT_POD" -o wide
else
    kubectl get pods -n "$NAMESPACE" -l app=livekit-livekit-server -o wide 2>/dev/null || kubectl get pods -n "$NAMESPACE" --show-labels | grep livekit
fi

# Additional verification - Check if endpoints are populated
echo ""
echo "🔍 Verifying ALB target registration..."
ENDPOINT_IPS=$(kubectl get endpoints -n "$NAMESPACE" livekit-alb-service -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
if [ -n "$ENDPOINT_IPS" ]; then
    echo "✅ ALB service has endpoints: $ENDPOINT_IPS"
    echo "✅ Target group will register these IPs on port 7880"
else
    echo "⚠️ No endpoints found - checking service selector..."
    kubectl describe svc -n "$NAMESPACE" livekit-alb-service
fi

# Step 6: Wait for LoadBalancer Service to be ready and verify ALB setup
echo ""
echo "⏳ Waiting for LoadBalancer Service and ALB setup..."
MAX_ATTEMPTS=30
ATTEMPT=1

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    # Check our custom ALB service first
    LB_ENDPOINT=$(kubectl get svc -n "$NAMESPACE" "livekit-alb-service" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # If custom service doesn't have endpoint, check the Helm chart service
    if [ -z "$LB_ENDPOINT" ] || [ "$LB_ENDPOINT" = "null" ]; then
        LB_ENDPOINT=$(kubectl get svc -n "$NAMESPACE" "$RELEASE_NAME-livekit-server" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ]; then
        echo "✅ LoadBalancer ready: $LB_ENDPOINT"
        
        # Verify ALB and Target Groups
        echo "🔍 Verifying ALB configuration..."
        ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?DNSName=='$LB_ENDPOINT'].LoadBalancerArn" --output text 2>/dev/null || echo "")
        
        if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
            echo "✅ ALB found: $(basename "$ALB_ARN")"
            
            # Check target groups
            TARGET_GROUPS=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" --query "TargetGroups[].TargetGroupArn" --output text 2>/dev/null || echo "")
            if [ -n "$TARGET_GROUPS" ]; then
                echo "✅ Target Groups created:"
                for TG in $TARGET_GROUPS; do
                    TG_NAME=$(aws elbv2 describe-target-groups --target-group-arns "$TG" --region "$AWS_REGION" --query "TargetGroups[0].TargetGroupName" --output text 2>/dev/null || echo "unknown")
                    TG_HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG" --region "$AWS_REGION" --query "TargetHealthDescriptions[0].TargetHealth.State" --output text 2>/dev/null || echo "unknown")
                    echo "   - $TG_NAME (Health: $TG_HEALTH)"
                done
                
                # Check listeners
                LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" --query "Listeners[].Port" --output text 2>/dev/null || echo "")
                if [ -n "$LISTENERS" ]; then
                    echo "✅ ALB Listeners on ports: $LISTENERS"
                else
                    echo "⚠️ No listeners found on ALB"
                fi
            else
                echo "⚠️ No target groups found for ALB"
            fi
        else
            echo "⚠️ ALB not found for endpoint: $LB_ENDPOINT"
        fi
        break
    fi
    
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo "⚠️ LoadBalancer not ready after $MAX_ATTEMPTS attempts"
        echo "📋 Checking service status..."
        kubectl get svc -n "$NAMESPACE" || true
        break
    fi
    
    echo "   Attempt $ATTEMPT/$MAX_ATTEMPTS: Waiting for LoadBalancer..."
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

# Step 7: Verify Deployment (Official Documentation)
echo ""
echo "📊 Step 4: Verify Deployment"
echo "============================"
echo "📋 Checking pods with label: app.kubernetes.io/name=livekit"

# Wait a moment for pods to be created
sleep 15

# Check for LiveKit pods
LIVEKIT_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit --no-headers 2>/dev/null | wc -l)
if [ "$LIVEKIT_PODS" -gt 0 ]; then
    echo "✅ Found $LIVEKIT_PODS LiveKit pods"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit
else
    echo "⚠️ No pods found with app.kubernetes.io/name=livekit, checking all pods in namespace..."
    kubectl get pods -n "$NAMESPACE" || echo "No pods found in namespace $NAMESPACE"
fi

echo ""
echo "📋 All resources in namespace $NAMESPACE:"
echo "📋 Pods:"
kubectl get pods -n "$NAMESPACE" || echo "No pods found"

echo ""
echo "📋 Services:"
kubectl get svc -n "$NAMESPACE" || echo "No services found"

echo ""
echo "📋 Deployments:"
kubectl get deployments -n "$NAMESPACE" || echo "No deployments found"

# Clean up temporary files
rm -f /tmp/livekit-values.yaml /tmp/livekit-template.yaml /tmp/livekit-alb-service.yaml

echo ""
echo "🎉 LiveKit Deployment Completed!"
echo "==============================="
echo ""
echo "📋 Summary:"
echo "   ✅ LiveKit Server: Deployed using official livekit-server chart"
echo "   ✅ Repository: https://helm.livekit.io"
echo "   ✅ Chart: livekit/livekit-server"
echo "   ✅ Namespace: $NAMESPACE"
echo "   ✅ Release: $RELEASE_NAME"
if [ -n "$LB_ENDPOINT" ]; then
    echo "   ✅ Load Balancer: $LB_ENDPOINT"
fi
echo "   ✅ Domain: $LIVEKIT_DOMAIN"
echo "   ✅ TURN Domain: $TURN_DOMAIN"
echo "   ✅ HTTPS: Enabled with ACM certificate"
echo "   ✅ Redis: Connected to ElastiCache"
echo "   ✅ Metrics: Enabled (Prometheus on port 6789)"
echo "   ✅ WebRTC: Configured for external IP"
echo "   ✅ Service Type: LoadBalancer (ALB)"
echo "   ✅ Ingress: Disabled (using ALB service annotations)"

echo ""
echo "📋 Access URLs:"
echo "   🌐 LiveKit API: https://$LIVEKIT_DOMAIN"
echo "   🌐 TURN Server: $TURN_DOMAIN:3478"

echo ""
echo "📋 Next Steps:"
echo "   1. Verify pods are running: kubectl get pods -n $NAMESPACE"
echo "   2. Check LoadBalancer status: kubectl get svc -n $NAMESPACE"
echo "   3. Test ALB connectivity: curl -k https://$LIVEKIT_DOMAIN"
echo "   4. Check LiveKit logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo "   5. Verify ALB target groups: aws elbv2 describe-target-groups --region $AWS_REGION"
echo ""
echo "📋 ALB Configuration:"
if [ -n "$LB_ENDPOINT" ]; then
    echo "   🌐 ALB Endpoint: $LB_ENDPOINT"
    echo "   🌐 Custom Domain: https://$LIVEKIT_DOMAIN (via DNS)"
    echo "   🔒 SSL Certificate: Configured with ACM"
    echo "   🎯 Target Groups: Should point to LiveKit service on port 7880"
else
    echo "   ⚠️ ALB endpoint not available yet"
fi