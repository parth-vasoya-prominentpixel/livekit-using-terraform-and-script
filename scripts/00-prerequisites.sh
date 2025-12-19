#!/bin/bash

# Prerequisites script for LiveKit EKS deployment
# This script checks required tools and AWS access

set -e

echo "🔧 LiveKit EKS Prerequisites Check"
echo "=================================="

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check AWS CLI
if command_exists aws; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
    echo "✅ AWS CLI: $AWS_VERSION"
else
    echo "❌ AWS CLI not found"
    exit 1
fi

# Check Terraform
if command_exists terraform; then
    TERRAFORM_VERSION=$(terraform version | head -n1 | cut -d' ' -f2)
    echo "✅ Terraform: $TERRAFORM_VERSION"
else
    echo "❌ Terraform not found"
    exit 1
fi

# Check kubectl
if command_exists kubectl; then
    KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "installed")
    echo "✅ kubectl: $KUBECTL_VERSION"
else
    echo "❌ kubectl not found"
    exit 1
fi

# Check Helm
if command_exists helm; then
    HELM_VERSION=$(helm version --short 2>/dev/null | cut -d' ' -f1 || echo "installed")
    echo "✅ Helm: $HELM_VERSION"
else
    echo "❌ Helm not found"
    exit 1
fi

# Check eksctl
if command_exists eksctl; then
    EKSCTL_VERSION=$(eksctl version 2>/dev/null || echo "installed")
    echo "✅ eksctl: $EKSCTL_VERSION"
else
    echo "❌ eksctl not found"
    exit 1
fi

# Check AWS credentials
echo ""
echo "🔐 Checking AWS credentials..."
if aws sts get-caller-identity >/dev/null 2>&1; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    echo "✅ AWS credentials configured"
    echo "   Account ID: $ACCOUNT_ID"
    echo "   User/Role:  $USER_ARN"
else
    echo "❌ AWS credentials not configured or invalid"
    exit 1
fi

# Check AWS region
echo ""
echo "🌍 Checking AWS region..."
if [[ -z "${AWS_REGION:-}" ]]; then
    echo "⚠️  AWS_REGION not set, using default: us-east-1"
    export AWS_REGION=us-east-1
else
    echo "✅ AWS_REGION: $AWS_REGION"
fi

# Check S3 backend access
echo ""
echo "🗄️  Checking S3 backend access..."
if [[ -f "../environments/livekit-poc/$AWS_REGION/dev/backend.tfvars" ]]; then
    BUCKET=$(grep 'bucket' "../environments/livekit-poc/$AWS_REGION/dev/backend.tfvars" | cut -d'"' -f2)
    if aws s3 ls "s3://$BUCKET" >/dev/null 2>&1; then
        echo "✅ S3 backend accessible: $BUCKET"
    else
        echo "❌ Cannot access S3 backend: $BUCKET"
        exit 1
    fi
else
    echo "⚠️  Backend config not found, skipping S3 check"
fi

echo ""
echo "🎉 All prerequisites check completed successfully!"
echo "Ready to proceed with LiveKit EKS deployment."