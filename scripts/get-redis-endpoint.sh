#!/bin/bash

# Simple script to get Redis endpoint from Terraform outputs
# Useful for testing and verification

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$ROOT_DIR/resources"

echo "🔍 Getting Redis endpoint from Terraform..."

if [ ! -d "$TERRAFORM_DIR" ]; then
    echo "❌ Terraform directory not found: $TERRAFORM_DIR"
    exit 1
fi

cd "$TERRAFORM_DIR"

if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
    echo "❌ Terraform state not found"
    echo "💡 Run terraform apply first to create infrastructure"
    exit 1
fi

REDIS_ENDPOINT=$(terraform output -raw redis_cluster_endpoint 2>/dev/null || echo "")

if [ -z "$REDIS_ENDPOINT" ] || [ "$REDIS_ENDPOINT" = "null" ]; then
    echo "❌ Redis endpoint not found in Terraform outputs"
    echo "💡 Available outputs:"
    terraform output 2>/dev/null || echo "   No outputs available"
    exit 1
fi

echo "✅ Redis endpoint: $REDIS_ENDPOINT"

# Also show other useful outputs
echo ""
echo "📋 Other useful outputs:"
echo "   Cluster name: $(terraform output -raw cluster_name 2>/dev/null || echo 'N/A')"
echo "   VPC ID: $(terraform output -raw vpc_id 2>/dev/null || echo 'N/A')"
echo "   Region: $(terraform output -json deployment_summary 2>/dev/null | jq -r '.region' 2>/dev/null || echo 'N/A')"