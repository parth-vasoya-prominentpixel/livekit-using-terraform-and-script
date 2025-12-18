#!/bin/bash

# Script to clean up existing EKS access entries that might conflict
echo "🧹 Cleaning up existing EKS access entries..."

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

print_status "info" "🔍 Checking for existing access entries..."

# Check if cluster exists
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    print_status "info" "Cluster $CLUSTER_NAME does not exist or is not accessible"
    exit 0
fi

# List existing access entries
print_status "info" "📋 Listing existing access entries..."
ACCESS_ENTRIES=$(aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'accessEntries[]' --output text 2>/dev/null || echo "")

if [ -z "$ACCESS_ENTRIES" ]; then
    print_status "success" "No existing access entries found"
    exit 0
fi

print_status "warning" "Found existing access entries:"
echo "$ACCESS_ENTRIES"

print_status "info" "🗑️ Automatically cleaning up conflicting access entries..."

# Delete each access entry
echo "$ACCESS_ENTRIES" | while read -r entry; do
    if [ -n "$entry" ]; then
        print_status "info" "🗑️ Deleting access entry: $entry"
        if aws eks delete-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$entry" --region "$REGION" 2>/dev/null; then
            print_status "success" "Deleted access entry: $entry"
        else
            print_status "warning" "Failed to delete or entry doesn't exist: $entry"
        fi
    fi
done

print_status "success" "🎉 Access entry cleanup completed!"
print_status "info" "💡 Terraform can now manage access entries without conflicts"