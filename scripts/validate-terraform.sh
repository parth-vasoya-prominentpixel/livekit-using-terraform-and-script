#!/bin/bash

# Terraform validation script
echo "🔍 Validating Terraform configuration..."

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../resources"

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

print_status "info" "🔧 Initializing Terraform (backend=false for validation)..."
if terraform init -backend=false; then
    print_status "success" "Terraform initialization completed"
else
    print_status "error" "Terraform initialization failed"
    exit 1
fi

print_status "info" "🔍 Running terraform validate..."
if terraform validate; then
    print_status "success" "Terraform configuration is valid"
else
    print_status "error" "Terraform validation failed"
    exit 1
fi

print_status "info" "📋 Running terraform fmt check..."
if terraform fmt -check; then
    print_status "success" "Terraform formatting is correct"
else
    print_status "warning" "Terraform formatting issues found - running fmt..."
    terraform fmt
    print_status "success" "Terraform formatting fixed"
fi

print_status "success" "🎉 All validation checks passed!"
print_status "info" "💡 Configuration is ready for deployment"

echo ""
print_status "info" "📋 Next steps:"
echo "   1. Run terraform plan to see what will be created"
echo "   2. Run terraform apply to deploy infrastructure"
echo "   3. Use GitHub Actions workflow for automated deployment"