#!/bin/bash

# Script to deploy LiveKit with proper configuration
set -e

echo "🚀 Deploying LiveKit..."

# Get Redis endpoint from environment or terraform
cd "$(dirname "$0")/../resources"

# Use environment variables if available (from CI/CD), otherwise get from terraform
if [ -n "$REDIS_ENDPOINT" ] && [ -n "$CLUSTER_NAME" ]; then
    echo "📝 Using environment variables for configuration"
else
    echo "📝 Getting configuration from Terraform outputs..."
    REDIS_ENDPOINT=$(terraform output -raw redis_cluster_endpoint)
    CLUSTER_NAME=$(terraform output -raw cluster_name)
fi

echo "📝 Using Redis endpoint: $REDIS_ENDPOINT"
echo "📝 Using Cluster: $CLUSTER_NAME"

# Step 1: Create namespace
echo "📁 Creating livekit namespace..."
kubectl create namespace livekit --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Set context to livekit namespace
echo "🔧 Setting kubectl context to livekit namespace..."
kubectl config set-context --current --namespace=livekit

# Step 3: Update LiveKit values file with correct Redis endpoint
echo "📝 Updating LiveKit values.yaml with Redis endpoint..."
cd "$(dirname "$0")/.."

# Use the template values file and replace Redis endpoint
LIVEKIT_VALUES_TEMPLATE="livekit-values.yaml"
LIVEKIT_VALUES_FILE="livekit-values-deployed.yaml"

if [ ! -f "$LIVEKIT_VALUES_TEMPLATE" ]; then
    echo "❌ LiveKit values template not found: $LIVEKIT_VALUES_TEMPLATE"
    exit 1
fi

# Create deployment values file by replacing the Redis endpoint placeholder
sed "s/REDIS_ENDPOINT_PLACEHOLDER/$REDIS_ENDPOINT/g" "$LIVEKIT_VALUES_TEMPLATE" > "$LIVEKIT_VALUES_FILE"

echo "📝 LiveKit values file updated: $LIVEKIT_VALUES_FILE"
echo "🔗 Redis endpoint set to: $REDIS_ENDPOINT"

# Step 4: Add LiveKit Helm repository
echo "📦 Adding LiveKit Helm repository..."
helm repo add livekit https://livekit.github.io/charts
helm repo update

# Step 5: Deploy LiveKit
echo "🚀 Deploying LiveKit with custom values..."
helm upgrade --install livekit livekit/livekit -f "$LIVEKIT_VALUES_FILE"

# Step 6: Verify deployment
echo "🔍 Verifying LiveKit deployment..."
kubectl get pods -l app.kubernetes.io/name=livekit

echo "🔍 Checking services..."
kubectl get services

echo "🔍 Checking ingress..."
kubectl get ingress

echo "✅ LiveKit deployment complete!"
echo "🌐 Your LiveKit server should be accessible at: https://livekit-eks.digi-telephony.com"
echo "📊 Monitor the deployment with: kubectl get pods -w"