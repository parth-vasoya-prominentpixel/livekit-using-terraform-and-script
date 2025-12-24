#!/bin/bash

# EMERGENCY ALB FIX SCRIPT
# Run this to immediately fix the ALB creation issue

set -e

echo "🚨 EMERGENCY ALB FIX - FORCING ALB CREATION"
echo "=========================================="

NAMESPACE="livekit"
AWS_REGION="us-east-1"
CERT_ARN="arn:aws:acm:us-east-1:918595516608:certificate/4523a895-7899-41a3-8589-2a5baed3b420"
LIVEKIT_DOMAIN="livekit-eks-tf.digi-telephony.com"

# Get security group
SG_NAME="livekit-alb-open-sg"
VPC_ID=$(aws eks describe-cluster --name "lp-eks-livekit-use1-dev" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
ALB_SECURITY_GROUP=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)

echo "📋 Using Security Group: $ALB_SECURITY_GROUP"

# 1. FORCE DELETE ALL EXISTING LOAD BALANCER SERVICES
echo ""
echo "🧹 Step 1: Force cleanup of all existing load balancer services..."
kubectl delete svc -n "$NAMESPACE" livekit-alb-service --ignore-not-found=true
kubectl delete svc -n "$NAMESPACE" --all --field-selector spec.type=LoadBalancer --ignore-not-found=true

# Wait for cleanup
echo "⏳ Waiting 30 seconds for cleanup..."
sleep 30

# 2. CHECK AWS LOAD BALANCER CONTROLLER
echo ""
echo "🔍 Step 2: Checking AWS Load Balancer Controller..."
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Restart the controller if needed
echo "🔄 Restarting AWS Load Balancer Controller..."
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

# 3. CREATE CLEAN ALB SERVICE
echo ""
echo "🔧 Step 3: Creating clean ALB service..."

# Get LiveKit pod labels
LIVEKIT_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep livekit | head -1)
echo "📋 Found LiveKit pod: $LIVEKIT_POD"

# Create the ALB service with minimal, working configuration
cat > /tmp/emergency-alb-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: livekit-alb-service
  namespace: $NAMESPACE
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "alb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: $CERT_ARN
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
    service.beta.kubernetes.io/aws-load-balancer-security-groups: $ALB_SECURITY_GROUP
    service.beta.kubernetes.io/aws-load-balancer-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "7880"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "http"
    external-dns.alpha.kubernetes.io/hostname: $LIVEKIT_DOMAIN
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: livekit-server
    app.kubernetes.io/instance: livekit
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

kubectl apply -f /tmp/emergency-alb-service.yaml

echo "✅ ALB service created"

# 4. MONITOR CREATION
echo ""
echo "⏳ Step 4: Monitoring ALB creation (will check for 5 minutes)..."

for i in {1..15}; do
    echo "🔍 Check $i/15: Looking for ALB endpoint..."
    
    LB_ENDPOINT=$(kubectl get svc -n "$NAMESPACE" livekit-alb-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_ENDPOINT" ] && [ "$LB_ENDPOINT" != "null" ]; then
        echo "🎉 SUCCESS! ALB Created: $LB_ENDPOINT"
        
        # Verify it's an ALB
        LB_TYPE=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?DNSName=='$LB_ENDPOINT'].Type" --output text 2>/dev/null || echo "unknown")
        echo "📋 Load Balancer Type: $LB_TYPE"
        
        if [ "$LB_TYPE" = "application" ]; then
            echo "✅ CONFIRMED: Application Load Balancer successfully created!"
            echo "🌐 Access URL: https://$LIVEKIT_DOMAIN"
            
            # Show target groups
            ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?DNSName=='$LB_ENDPOINT'].LoadBalancerArn" --output text)
            TARGET_GROUPS=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" --query "TargetGroups[].TargetGroupName" --output text 2>/dev/null || echo "")
            echo "📋 Target Groups: $TARGET_GROUPS"
            
            exit 0
        fi
    fi
    
    # Show current status
    kubectl get svc -n "$NAMESPACE" livekit-alb-service --no-headers | awk '{print "   Status: " $4}'
    
    # Check for errors in controller logs
    ERROR_LOGS=$(kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10 --since=30s | grep -i "error\|failed" | tail -2 || echo "")
    if [ -n "$ERROR_LOGS" ]; then
        echo "⚠️ Recent controller errors:"
        echo "$ERROR_LOGS"
    fi
    
    sleep 20
done

echo "❌ ALB creation timed out after 5 minutes"
echo ""
echo "🔍 FINAL DIAGNOSTICS:"
echo "===================="

echo "📋 Service status:"
kubectl get svc -n "$NAMESPACE" livekit-alb-service

echo ""
echo "📋 Service description:"
kubectl describe svc -n "$NAMESPACE" livekit-alb-service

echo ""
echo "📋 AWS Load Balancer Controller logs (last 20 lines):"
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20

echo ""
echo "📋 All existing load balancers:"
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,Type:Type}" --output table

# Cleanup
rm -f /tmp/emergency-alb-service.yaml

echo ""
echo "💡 If this still doesn't work, the issue might be:"
echo "   1. AWS Load Balancer Controller permissions"
echo "   2. VPC/Subnet configuration"
echo "   3. Security group conflicts"
echo "   4. Certificate ARN issues"