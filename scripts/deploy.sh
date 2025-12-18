#!/bin/bash

# Simple manual deployment script
echo "🚀 Manual LiveKit EKS Deployment"
echo "================================"

# Deploy infrastructure
echo "1. Deploying infrastructure..."
cd ../resources
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars" -auto-approve

# Get cluster info
CLUSTER_NAME=$(terraform output -raw cluster_name)
echo "Cluster: $CLUSTER_NAME"

# Configure kubectl
echo "2. Configuring kubectl..."
aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER_NAME"
kubectl get nodes

echo "✅ Infrastructure deployed! Use GitHub Actions for Load Balancer and LiveKit deployment."