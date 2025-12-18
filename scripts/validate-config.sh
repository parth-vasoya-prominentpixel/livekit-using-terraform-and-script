#!/bin/bash

# Simple validation script for Terraform configuration
echo "🔍 Validating Terraform Configuration"
echo "===================================="

cd resources

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

print_status "info" "Checking Terraform configuration syntax..."

# Initialize Terraform (required for validation)
if terraform init -backend=false > /dev/null 2>&1; then
    print_status "success" "Terraform initialization successful"
else
    print_status "error" "Terraform initialization failed"
    exit 1
fi

# Validate configuration
if terraform validate; then
    print_status "success" "Terraform configuration is valid!"
else
    print_status "error" "Terraform configuration validation failed"
    exit 1
fi

print_status "info" "Checking for common issues..."

# Check for required files
BACKEND_CONFIG="../environments/livekit-poc/us-east-1/dev/backend.tfvars"
INPUT_CONFIG="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

if [ -f "$BACKEND_CONFIG" ]; then
    print_status "success" "Backend configuration found"
else
    print_status "error" "Backend configuration not found: $BACKEND_CONFIG"
fi

if [ -f "$INPUT_CONFIG" ]; then
    print_status "success" "Input configuration found"
else
    print_status "error" "Input configuration not found: $INPUT_CONFIG"
fi

print_status "success" "🎉 Configuration validation completed!"