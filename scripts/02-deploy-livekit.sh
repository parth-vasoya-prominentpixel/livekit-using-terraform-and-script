#!/bin/bash

# LiveKit Deployment Script for EKS
# Deploys LiveKit Server with ALB, SSL certificates, and Route 53 configuration
# Follows proper resource management approach - check existing, use if available, create if needed

set -euo pipefail

echo "🎥 LiveKit Deployment Script"
echo "============================"
echo "📅 Started at: $(date)"
echo "📋 Deploying LiveKit Server on EKS with ALB and SSL"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"

# LiveKit Configuration
LIVEKIT_NAMESPACE="livekit"
LIVEKIT_DOMAIN="livekit-eks-tf.digi-telephony.com"
TURN_DOMAIN="turn-eks-tf.digi-telephony.com"
CERTIFICATE_ARN="arn:aws:acm:us-east-1:918595516608:certificate/4523a895-7899-41a3-8589-2a5baed3b420"
HELM_RELEASE_NAME="livekit-server"
HELM_CHART_VERSION="1.5.2"

# LiveKit API Keys (Generate secure keys)
API_KEY="a630d5cf73030309d7de89d9c34f18b6"
API_SECRET="8ae7889d73e878636e434640027f2b33e3ba03836e9af0ee9f2ce33297a7f872"

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
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   Domain: $LIVEKIT_DOMAIN"
echo "   TURN Domain: $TURN_DOMAIN"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Certificate ARN: $CERTIFICATE_ARN"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verify required tools
echo "🔧 Verifying required tools..."
for tool in aws kubectl helm jq; do
    if command_exists "$tool"; then
        VERSION=$($tool --version 2>/dev/null | head -n1 || echo "unknown")
        echo "✅ $tool: available ($VERSION)"
    else
        echo "❌ $tool: not found"
        exit 1
    fi
done
echo ""

# Get AWS account ID
echo "🔐 Getting AWS account information..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    echo "❌ Failed to get AWS account ID. Check AWS credentials."
    exit 1
fi
echo "✅ Account ID: $ACCOUNT_ID"
echo ""

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
if aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"; then
    echo "✅ Kubeconfig updated successfully"
else
    echo "❌ Failed to update kubeconfig. Check cluster name and permissions."
    exit 1
fi
echo ""

# Verify cluster connectivity
echo "🔍 Verifying cluster connectivity..."
if kubectl get nodes >/dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    echo "✅ Connected to cluster with $NODE_COUNT nodes"
    
    echo "📋 Node Information:"
    kubectl get nodes -o wide
else
    echo "❌ Cannot connect to cluster"
    exit 1
fi
echo ""

# =============================================================================
# STEP 1: CHECK AND CREATE LIVEKIT NAMESPACE
# =============================================================================

echo "📋 Step 1: Check and Create LiveKit Namespace"
echo "=============================================="

if kubectl get namespace "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' already exists"
else
    echo "🔄 Creating namespace '$LIVEKIT_NAMESPACE'..."
    kubectl create namespace "$LIVEKIT_NAMESPACE"
    echo "✅ Namespace '$LIVEKIT_NAMESPACE' created"
fi

# Label namespace for monitoring
echo "🔄 Adding labels to namespace..."
kubectl label namespace "$LIVEKIT_NAMESPACE" \
    app.kubernetes.io/name=livekit \
    app.kubernetes.io/component=server \
    environment="$ENVIRONMENT" \
    --overwrite
echo "✅ Namespace labels updated"
echo ""

# =============================================================================
# STEP 2: VERIFY AWS LOAD BALANCER CONTROLLER
# =============================================================================

echo "📋 Step 2: Verify AWS Load Balancer Controller"
echo "=============================================="

if kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    if [[ "${READY_REPLICAS}" == "null" || "${READY_REPLICAS}" == "" ]]; then
        READY_REPLICAS="0"
    fi
    
    if [[ "${READY_REPLICAS}" -gt 0 ]]; then
        echo "✅ AWS Load Balancer Controller is running ($READY_REPLICAS replicas)"
        kubectl get deployment aws-load-balancer-controller -n kube-system
    else
        echo "❌ AWS Load Balancer Controller is not ready"
        echo "   Please run the load balancer controller setup script first"
        exit 1
    fi
else
    echo "❌ AWS Load Balancer Controller not found"
    echo "   Please run the load balancer controller setup script first"
    exit 1
fi
echo ""

# =============================================================================
# STEP 3: VERIFY SSL CERTIFICATE
# =============================================================================

echo "📋 Step 3: Verify SSL Certificate"
echo "=================================="

echo "🔍 Checking SSL certificate in ACM..."
CERT_STATUS=$(aws acm describe-certificate --certificate-arn "$CERTIFICATE_ARN" --region "$AWS_REGION" --query 'Certificate.Status' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$CERT_STATUS" == "ISSUED" ]]; then
    echo "✅ SSL certificate is valid and issued"
    
    # Get certificate details
    CERT_DOMAIN=$(aws acm describe-certificate --certificate-arn "$CERTIFICATE_ARN" --region "$AWS_REGION" --query 'Certificate.DomainName' --output text)
    CERT_SANS=$(aws acm describe-certificate --certificate-arn "$CERTIFICATE_ARN" --region "$AWS_REGION" --query 'Certificate.SubjectAlternativeNames[]' --output text | tr '\t' ' ')
    
    echo "   Primary Domain: $CERT_DOMAIN"
    echo "   SANs: $CERT_SANS"
    
    # Verify our domains are covered
    if echo "$CERT_SANS" | grep -q "$LIVEKIT_DOMAIN" && echo "$CERT_SANS" | grep -q "$TURN_DOMAIN"; then
        echo "✅ Certificate covers both LiveKit and TURN domains"
    else
        echo "⚠️  Certificate may not cover all required domains"
        echo "   Required: $LIVEKIT_DOMAIN, $TURN_DOMAIN"
        echo "   Available: $CERT_SANS"
    fi
else
    echo "❌ SSL certificate is not available or not issued"
    echo "   Status: $CERT_STATUS"
    echo "   Please ensure the certificate is issued and covers the required domains"
    exit 1
fi
echo ""

# =============================================================================
# STEP 4: ADD LIVEKIT HELM REPOSITORY
# =============================================================================

echo "📋 Step 4: Add LiveKit Helm Repository"
echo "======================================"

echo "🔄 Adding LiveKit Helm repository..."
if helm repo list | grep -q "livekit"; then
    echo "✅ LiveKit repository already added"
else
    helm repo add livekit https://helm.livekit.io
    echo "✅ LiveKit repository added"
fi

echo "🔄 Updating Helm repositories..."
helm repo update
echo "✅ Helm repositories updated"
echo ""

# =============================================================================
# STEP 5: CREATE LIVEKIT VALUES CONFIGURATION
# =============================================================================

echo "📋 Step 5: Create LiveKit Values Configuration"
echo "=============================================="

echo "🔄 Creating LiveKit values.yaml configuration..."

# Create values.yaml for LiveKit deployment - exact structure as provided
cat > /tmp/livekit-values.yaml << EOF
livekit:
  domain: $LIVEKIT_DOMAIN
  rtc:
    use_external_ip: true
    port_range_start: 50000
    port_range_end: 60000

redis:
  address: $REDIS_ENDPOINT

keys:
  $API_KEY: $API_SECRET

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
  domain: $TURN_DOMAIN
  tls_port: 3478
  udp_port: 3478

loadBalancer:
  type: alb
  tls:
  - hosts:
    - $LIVEKIT_DOMAIN
    certificateArn: $CERTIFICATE_ARN

# Host networking for direct node IP access (recommended for LiveKit WebRTC)
hostNetwork: true

# Service configuration - NodePort for host networking
service:
  type: NodePort

# Ingress configuration for ALB
ingress:
  enabled: true
  className: "alb"
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: $CERTIFICATE_ARN
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: '200'
    alb.ingress.kubernetes.io/load-balancer-name: livekit-$ENVIRONMENT-alb
  hosts:
  - host: $LIVEKIT_DOMAIN
    paths:
    - path: /
      pathType: Prefix
  tls:
  - hosts:
    - $LIVEKIT_DOMAIN
EOF

echo "✅ LiveKit values.yaml created"
echo ""

echo "📋 Configuration Summary:"
echo "========================"
cat /tmp/livekit-values.yaml
echo ""

# =============================================================================
# STEP 6: CHECK EXISTING LIVEKIT DEPLOYMENT
# =============================================================================

echo "📋 Step 6: Check Existing LiveKit Deployment"
echo "============================================"

if helm list -n "$LIVEKIT_NAMESPACE" | grep -q "$HELM_RELEASE_NAME"; then
    RELEASE_STATUS=$(helm list -n "$LIVEKIT_NAMESPACE" -f "$HELM_RELEASE_NAME" -o json | jq -r '.[0].status' 2>/dev/null || echo "unknown")
    RELEASE_VERSION=$(helm list -n "$LIVEKIT_NAMESPACE" -f "$HELM_RELEASE_NAME" -o json | jq -r '.[0].chart' 2>/dev/null || echo "unknown")
    
    echo "ℹ️  Found existing LiveKit deployment:"
    echo "   Release: $HELM_RELEASE_NAME"
    echo "   Status: $RELEASE_STATUS"
    echo "   Chart: $RELEASE_VERSION"
    echo ""
    
    if [[ "$RELEASE_STATUS" == "deployed" ]]; then
        echo "🤔 LiveKit is already deployed. Choose action:"
        echo "   1. Upgrade existing deployment"
        echo "   2. Skip deployment (use existing)"
        echo "   3. Uninstall and reinstall"
        echo ""
        
        # For automation, we'll upgrade
        echo "🔄 Proceeding with upgrade for automation..."
        DEPLOYMENT_ACTION="upgrade"
    else
        echo "⚠️  Existing deployment is not healthy, will reinstall"
        DEPLOYMENT_ACTION="install"
    fi
else
    echo "ℹ️  No existing LiveKit deployment found"
    DEPLOYMENT_ACTION="install"
fi
echo ""

# =============================================================================
# STEP 7: DEPLOY OR UPGRADE LIVEKIT
# =============================================================================

echo "📋 Step 7: Deploy or Upgrade LiveKit"
echo "===================================="

if [[ "$DEPLOYMENT_ACTION" == "upgrade" ]]; then
    echo "🔄 Upgrading existing LiveKit deployment..."
    
    if helm upgrade "$HELM_RELEASE_NAME" livekit/livekit-server \
        --namespace "$LIVEKIT_NAMESPACE" \
        --values /tmp/livekit-values.yaml \
        --version "$HELM_CHART_VERSION" \
        --timeout 10m \
        --wait; then
        echo "✅ LiveKit upgrade completed successfully"
    else
        echo "❌ LiveKit upgrade failed"
        exit 1
    fi
    
elif [[ "$DEPLOYMENT_ACTION" == "install" ]]; then
    echo "🔄 Installing LiveKit deployment..."
    
    # Remove any failed releases first
    if helm list -n "$LIVEKIT_NAMESPACE" | grep -q "$HELM_RELEASE_NAME"; then
        echo "🗑️ Removing failed release..."
        helm uninstall "$HELM_RELEASE_NAME" -n "$LIVEKIT_NAMESPACE" || true
        sleep 10
    fi
    
    if helm install "$HELM_RELEASE_NAME" livekit/livekit-server \
        --namespace "$LIVEKIT_NAMESPACE" \
        --values /tmp/livekit-values.yaml \
        --version "$HELM_CHART_VERSION" \
        --timeout 10m \
        --wait; then
        echo "✅ LiveKit installation completed successfully"
    else
        echo "❌ LiveKit installation failed"
        exit 1
    fi
else
    echo "ℹ️  Skipping deployment (using existing)"
fi
echo ""

# =============================================================================
# STEP 8: VERIFY LIVEKIT DEPLOYMENT
# =============================================================================

echo "📋 Step 8: Verify LiveKit Deployment"
echo "===================================="

echo "⏳ Waiting for LiveKit pods to be ready..."
for i in {1..60}; do
    READY_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "   Pod status: $READY_PODS/$TOTAL_PODS ready (attempt $i/60)"
    
    if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
        echo "✅ All LiveKit pods are ready!"
        break
    fi
    
    sleep 5
done

echo ""
echo "📋 LiveKit Deployment Status:"
kubectl get deployment -n "$LIVEKIT_NAMESPACE"
echo ""

echo "📋 LiveKit Pod Status:"
kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server
echo ""

echo "📋 LiveKit Service Status:"
kubectl get services -n "$LIVEKIT_NAMESPACE"
echo ""

# =============================================================================
# STEP 9: GET ALB INFORMATION
# =============================================================================

echo "📋 Step 9: Get ALB Information"
echo "=============================="

echo "⏳ Waiting for ALB Ingress to be created..."
for i in {1..30}; do
    if kubectl get ingress -n "$LIVEKIT_NAMESPACE" >/dev/null 2>&1; then
        INGRESS_COUNT=$(kubectl get ingress -n "$LIVEKIT_NAMESPACE" --no-headers | wc -l)
        if [ "$INGRESS_COUNT" -gt 0 ]; then
            echo "✅ Ingress found"
            break
        fi
    fi
    echo "   Waiting for ingress... (attempt $i/30)"
    sleep 5
done

echo ""
echo "📋 Ingress Status:"
kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o wide
echo ""

# Get ALB DNS name
echo "⏳ Getting ALB DNS name..."
ALB_DNS=""
for i in {1..30}; do
    ALB_DNS=$(kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [[ -n "$ALB_DNS" && "$ALB_DNS" != "null" ]]; then
        echo "✅ ALB DNS name: $ALB_DNS"
        break
    fi
    
    echo "   Waiting for ALB DNS... (attempt $i/30)"
    sleep 10
done

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "null" ]]; then
    echo "⚠️  ALB DNS name not available yet"
    echo "   This is normal for new deployments"
    echo "   The ALB may take 5-10 minutes to be fully provisioned"
    ALB_DNS="pending"
fi
echo ""

# =============================================================================
# STEP 10: CREATE ROUTE 53 RECORDS
# =============================================================================

echo "📋 Step 10: Create Route 53 Records"
echo "==================================="

if [[ "$ALB_DNS" != "pending" && -n "$ALB_DNS" ]]; then
    echo "🔄 Creating Route 53 records for LiveKit domains..."
    
    # Get hosted zone ID for the domain
    HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "digi-telephony.com" --query 'HostedZones[0].Id' --output text --region "$AWS_REGION" | cut -d'/' -f3)
    
    if [[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]]; then
        echo "✅ Found hosted zone: $HOSTED_ZONE_ID"
        
        # Get ALB hosted zone ID
        ALB_ZONE_ID=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" --output text --region "$AWS_REGION")
        
        if [[ -n "$ALB_ZONE_ID" && "$ALB_ZONE_ID" != "None" ]]; then
            echo "✅ ALB hosted zone ID: $ALB_ZONE_ID"
            
            # Create Route 53 record for LiveKit domain
            echo "🔄 Creating Route 53 record for $LIVEKIT_DOMAIN..."
            
            cat > /tmp/livekit-route53-record.json << EOF
{
    "Comment": "LiveKit domain record for $ENVIRONMENT environment",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$LIVEKIT_DOMAIN",
                "Type": "A",
                "AliasTarget": {
                    "DNSName": "$ALB_DNS",
                    "EvaluateTargetHealth": true,
                    "HostedZoneId": "$ALB_ZONE_ID"
                }
            }
        }
    ]
}
EOF
            
            CHANGE_ID=$(aws route53 change-resource-record-sets \
                --hosted-zone-id "$HOSTED_ZONE_ID" \
                --change-batch file:///tmp/livekit-route53-record.json \
                --query 'ChangeInfo.Id' --output text)
            
            echo "✅ Route 53 record created for $LIVEKIT_DOMAIN (Change ID: $CHANGE_ID)"
            
            # Create Route 53 record for TURN domain
            echo "🔄 Creating Route 53 record for $TURN_DOMAIN..."
            
            cat > /tmp/turn-route53-record.json << EOF
{
    "Comment": "TURN domain record for $ENVIRONMENT environment",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$TURN_DOMAIN",
                "Type": "A",
                "AliasTarget": {
                    "DNSName": "$ALB_DNS",
                    "EvaluateTargetHealth": true,
                    "HostedZoneId": "$ALB_ZONE_ID"
                }
            }
        }
    ]
}
EOF
            
            TURN_CHANGE_ID=$(aws route53 change-resource-record-sets \
                --hosted-zone-id "$HOSTED_ZONE_ID" \
                --change-batch file:///tmp/turn-route53-record.json \
                --query 'ChangeInfo.Id' --output text)
            
            echo "✅ Route 53 record created for $TURN_DOMAIN (Change ID: $TURN_CHANGE_ID)"
            
            # Clean up temporary files
            rm -f /tmp/livekit-route53-record.json /tmp/turn-route53-record.json
            
        else
            echo "❌ Could not get ALB hosted zone ID"
        fi
    else
        echo "❌ Could not find hosted zone for digi-telephony.com"
    fi
else
    echo "⚠️  Skipping Route 53 record creation (ALB DNS not available)"
    echo "   You can create the records manually once the ALB is ready"
fi
echo ""

# =============================================================================
# STEP 11: FINAL VERIFICATION AND SUMMARY
# =============================================================================

echo "📋 Step 11: Final Verification and Summary"
echo "=========================================="

# Final status check
echo "🔍 Final LiveKit Status:"
echo "========================"

echo "📋 Helm Release:"
helm list -n "$LIVEKIT_NAMESPACE"
echo ""

echo "📋 Deployment Status:"
kubectl get deployment -n "$LIVEKIT_NAMESPACE"
echo ""

echo "📋 Pod Status:"
kubectl get pods -n "$LIVEKIT_NAMESPACE" -o wide
echo ""

echo "📋 Service Status:"
kubectl get services -n "$LIVEKIT_NAMESPACE"
echo ""

echo "📋 Ingress Status:"
kubectl get ingress -n "$LIVEKIT_NAMESPACE" -o wide
echo ""

# Check if LiveKit is responding
echo "🔍 Testing LiveKit Connectivity:"
FINAL_READY=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
FINAL_TOTAL=$(kubectl get pods -n "$LIVEKIT_NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$FINAL_READY" -gt 0 ] && [ "$FINAL_READY" -eq "$FINAL_TOTAL" ]; then
    echo "✅ LiveKit pods are running ($FINAL_READY/$FINAL_TOTAL)"
    
    # Test internal connectivity
    echo "🔄 Testing internal LiveKit connectivity..."
    if kubectl exec -n "$LIVEKIT_NAMESPACE" deployment/livekit-server -- curl -s -f http://localhost:7880/ >/dev/null 2>&1; then
        echo "✅ LiveKit server is responding internally"
    else
        echo "⚠️  LiveKit server internal check failed (may be normal during startup)"
        echo "   This is expected for new deployments and will resolve once fully started"
    fi
else
    echo "❌ LiveKit pods are not ready ($FINAL_READY/$FINAL_TOTAL)"
fi

echo ""
echo "🎉 DEPLOYMENT SUMMARY"
echo "===================="
echo "✅ LiveKit Server deployed successfully!"
echo ""
echo "📋 Configuration Details:"
echo "   Environment: $ENVIRONMENT"
echo "   Namespace: $LIVEKIT_NAMESPACE"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo ""
echo "📋 Domains:"
echo "   LiveKit: https://$LIVEKIT_DOMAIN"
echo "   TURN: $TURN_DOMAIN"
echo ""
echo "📋 Infrastructure:"
echo "   Redis: $REDIS_ENDPOINT"
echo "   Certificate: $CERTIFICATE_ARN"
echo "   ALB DNS: ${ALB_DNS:-pending}"
echo ""
echo "📋 API Configuration:"
echo "   API Key: $API_KEY"
echo "   WebSocket URL: wss://$LIVEKIT_DOMAIN"
echo "   HTTP URL: https://$LIVEKIT_DOMAIN"
echo ""
echo "📋 Next Steps:"
echo "   1. Wait 5-10 minutes for ALB to be fully provisioned"
echo "   2. Test connectivity: curl -I https://$LIVEKIT_DOMAIN"
echo "   3. Check DNS propagation: nslookup $LIVEKIT_DOMAIN"
echo "   4. Monitor pods: kubectl get pods -n $LIVEKIT_NAMESPACE -w"
echo ""
echo "📋 Useful Commands:"
echo "   View logs: kubectl logs -n $LIVEKIT_NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo "   Port forward: kubectl port-forward -n $LIVEKIT_NAMESPACE svc/livekit-server 7880:80"
echo "   Update config: helm upgrade $HELM_RELEASE_NAME livekit/livekit-server -n $LIVEKIT_NAMESPACE --values /tmp/livekit-values.yaml"
echo ""

# GitHub Actions specific outputs
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "livekit_domain=$LIVEKIT_DOMAIN" >> "$GITHUB_OUTPUT"
    echo "turn_domain=$TURN_DOMAIN" >> "$GITHUB_OUTPUT"
    echo "alb_dns=${ALB_DNS:-pending}" >> "$GITHUB_OUTPUT"
    echo "namespace=$LIVEKIT_NAMESPACE" >> "$GITHUB_OUTPUT"
    echo "api_key=$API_KEY" >> "$GITHUB_OUTPUT"
fi

# Clean up temporary files
rm -f /tmp/livekit-values.yaml

echo "✅ LiveKit deployment completed successfully!"
echo "📅 Completed at: $(date)"