#!/bin/bash

# LiveKit Deployment Script - Simple Working Setup
set -e

echo "🎥 LiveKit Deployment"
echo "===================="

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/livekit.env"

# Basic setup
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Get Redis endpoint
cd "$ROOT_DIR/resources"
REDIS_ENDPOINT=$(terraform output -raw redis_cluster_endpoint)
cd "$ROOT_DIR"

# Setup Helm
helm repo add livekit https://helm.livekit.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Check for SSL certificate
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='*.digi-telephony.com'].CertificateArn" \
    --output text 2>/dev/null | head -1)

USE_TLS=false
if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    CERT_STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$AWS_REGION" --query 'Certificate.Status' --output text 2>/dev/null)
    if [ "$CERT_STATUS" = "ISSUED" ]; then
        USE_TLS=true
    fi
fi

# Create values.yaml
cat > /tmp/livekit-values.yaml << EOF
replicaCount: 2

livekit:
  rtc:
    use_external_ip: true
  redis:
    address: $REDIS_ENDPOINT
  keys:
    $API_KEY: $SECRET_KEY

ingress:
  enabled: true
  className: "alb"
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
EOF

if [ "$USE_TLS" = true ]; then
    cat >> /tmp/livekit-values.yaml << EOF
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: $CERT_ARN
    alb.ingress.kubernetes.io/ssl-redirect: '443'
EOF
else
    cat >> /tmp/livekit-values.yaml << EOF
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
EOF
fi

cat >> /tmp/livekit-values.yaml << EOF
  hosts:
    - host: livekit-eks-tf.digi-telephony.com
      paths:
        - path: /
          pathType: Prefix

service:
  type: ClusterIP
  port: 7880

resources:
  limits:
    cpu: $CPU_LIMIT
    memory: $MEMORY_LIMIT
  requests:
    cpu: $CPU_REQUEST
    memory: $MEMORY_REQUEST
EOF

# Clean up existing deployment
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait || true
sleep 10

# Deploy LiveKit
helm install "$RELEASE_NAME" livekit/livekit-server \
    -n "$NAMESPACE" \
    -f /tmp/livekit-values.yaml \
    --wait --timeout=10m

# Wait for ALB
echo "⏳ Waiting for ALB..."
for i in {1..30}; do
    ALB_ENDPOINT=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_ENDPOINT" ]; then
        echo "✅ ALB ready: $ALB_ENDPOINT"
        break
    fi
    sleep 10
done

# Show status
kubectl get pods -n "$NAMESPACE"
kubectl get ingress -n "$NAMESPACE"

echo "✅ LiveKit deployed!"
if [ -n "$ALB_ENDPOINT" ]; then
    echo "🔗 Endpoint: $ALB_ENDPOINT"
fi

rm -f /tmp/livekit-values.yaml