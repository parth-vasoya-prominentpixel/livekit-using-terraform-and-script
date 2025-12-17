#!/bin/bash

# Master deployment script for LiveKit on EKS
set -e

echo "🚀 LiveKit EKS Deployment - Complete Setup"
echo "=========================================="

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Check prerequisites
echo "Step 1: Checking prerequisites..."
bash "$SCRIPT_DIR/00-prerequisites.sh"

# Ask for confirmation
echo ""
read -p "🤔 Do you want to proceed with the full deployment? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Deployment cancelled."
    exit 1
fi

# Step 2: Deploy infrastructure
echo ""
echo "Step 2: Deploying infrastructure (EKS, VPC, Redis)..."
bash "$SCRIPT_DIR/01-deploy-infrastructure.sh"

# Step 3: Setup Load Balancer Controller
echo ""
echo "Step 3: Setting up AWS Load Balancer Controller..."
bash "$SCRIPT_DIR/02-setup-load-balancer.sh"

# Step 4: Deploy LiveKit
echo ""
echo "Step 4: Deploying LiveKit..."
bash "$SCRIPT_DIR/03-deploy-livekit.sh"

echo ""
echo "🎉 Complete LiveKit EKS deployment finished!"
echo "📋 Summary:"
echo "   ✅ EKS Cluster deployed with proper security groups"
echo "   ✅ Redis ElastiCache configured"
echo "   ✅ AWS Load Balancer Controller installed"
echo "   ✅ LiveKit deployed with ALB ingress"
echo ""
echo "🌐 Your LiveKit server should be accessible at:"
echo "   https://livekit-eks.digi-telephony.com"
echo ""
echo "📊 Monitor your deployment:"
echo "   kubectl get pods -n livekit -w"
echo "   kubectl get ingress -n livekit"
echo "   kubectl logs -n livekit -l app.kubernetes.io/name=livekit"