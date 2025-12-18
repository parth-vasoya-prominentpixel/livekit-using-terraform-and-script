#!/bin/bash

# Simple cleanup script for LiveKit EKS infrastructure
echo "🧹 Simple LiveKit EKS Cleanup"
echo "============================="

# Configuration
CLUSTER_NAME="lp-eks-livekit-use1-dev"
REGION=${AWS_REGION:-"us-east-1"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "success") echo -e "${GREEN}✅ $message${NC}" ;;
        "error") echo -e "${RED}❌ $message${NC}" ;;
        "warning") echo -e "${YELLOW}⚠️ $message${NC}" ;;
        "info") echo -e "ℹ️ $message" ;;
    esac
}

print_status "info" "🔍 Starting cleanup process..."

# Check if cluster exists and clean up Kubernetes resources
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    print_status "info" "📋 Found cluster: $CLUSTER_NAME"
    
    # Configure kubectl
    if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" 2>/dev/null; then
        print_status "success" "kubectl configured successfully"
        
        # Delete LiveKit namespace (this will clean up all LiveKit resources)
        print_status "info" "🗑️ Deleting LiveKit namespace..."
        kubectl delete namespace livekit --ignore-not-found=true --timeout=60s 2>/dev/null || print_status "warning" "LiveKit namespace cleanup timed out"
        
        # Delete AWS Load Balancer Controller
        print_status "info" "🗑️ Deleting AWS Load Balancer Controller..."
        helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || print_status "warning" "Load Balancer Controller not found"
        
        # Wait a bit for resources to clean up
        print_status "info" "⏳ Waiting for Kubernetes resources to clean up..."
        sleep 30
    else
        print_status "warning" "Could not configure kubectl - cluster may be inaccessible"
    fi
else
    print_status "info" "No cluster found - skipping Kubernetes cleanup"
fi

print_status "success" "🎉 Kubernetes cleanup completed!"
print_status "info" "💡 Now run terraform destroy to remove AWS infrastructure"