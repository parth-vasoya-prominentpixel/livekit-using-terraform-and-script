#!/bin/bash

# Enhanced script to deploy the EKS infrastructure with error handling
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "success") echo -e "${GREEN}✅ $message${NC}" ;;
        "error") echo -e "${RED}❌ $message${NC}" ;;
        "warning") echo -e "${YELLOW}⚠️ $message${NC}" ;;
        "info") echo -e "${BLUE}ℹ️ $message${NC}" ;;
    esac
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    local line_number=$1
    print_status "error" "An error occurred on line $line_number. Exit code: $exit_code"
    print_status "info" "Check the logs above for more details"
    exit $exit_code
}

# Set error trap
trap 'handle_error $LINENO' ERR

# Function to retry command
retry_command() {
    local max_attempts=$1
    local delay=$2
    local command="${@:3}"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_status "info" "Attempt $attempt/$max_attempts: Running command"
        
        if eval "$command"; then
            print_status "success" "Command succeeded on attempt $attempt"
            return 0
        else
            if [ $attempt -eq $max_attempts ]; then
                print_status "error" "Command failed after $max_attempts attempts"
                return 1
            fi
            
            print_status "warning" "Command failed, retrying in ${delay}s..."
            sleep $delay
            attempt=$((attempt + 1))
        fi
    done
}

print_status "info" "🚀 Starting infrastructure deployment..."

# Check prerequisites
print_status "info" "Checking prerequisites..."
if ! command -v terraform &> /dev/null; then
    print_status "error" "Terraform is not installed. Please run ./00-prerequisites.sh first"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    print_status "error" "AWS CLI is not installed. Please run ./00-prerequisites.sh first"
    exit 1
fi

# Check AWS credentials
print_status "info" "Verifying AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    print_status "error" "AWS credentials not configured. Please run 'aws configure'"
    exit 1
fi

print_status "success" "Prerequisites check passed"

# Navigate to terraform directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../resources"

if [ ! -d "$TERRAFORM_DIR" ]; then
    print_status "error" "Terraform directory not found: $TERRAFORM_DIR"
    exit 1
fi

cd "$TERRAFORM_DIR"
print_status "info" "Working directory: $(pwd)"

# Set environment variables
export TF_IN_AUTOMATION=true
export TF_INPUT=false

# Initialize Terraform with S3 backend
print_status "info" "🔧 Initializing Terraform with S3 backend..."
BACKEND_CONFIG_FILE="../environments/livekit-poc/$REGION/$ENVIRONMENT/backend.tfvars"

if [ -f "$BACKEND_CONFIG_FILE" ]; then
    print_status "info" "Using S3 backend configuration: $BACKEND_CONFIG_FILE"
    print_status "info" "Backend config contents:"
    cat "$BACKEND_CONFIG_FILE"
    
    if retry_command 3 5 "terraform init -upgrade -backend-config=$BACKEND_CONFIG_FILE"; then
        print_status "success" "Terraform initialized successfully with S3 backend"
    else
        print_status "error" "Failed to initialize Terraform with S3 backend"
        exit 1
    fi
else
    print_status "error" "Backend config file not found: $BACKEND_CONFIG_FILE"
    print_status "info" "Available files in environments directory:"
    find ../environments -name "*.tfvars" -type f 2>/dev/null || echo "No tfvars files found"
    exit 1
fi

# Validate Terraform configuration
print_status "info" "🔍 Validating Terraform configuration..."
if terraform validate; then
    print_status "success" "Terraform configuration is valid"
else
    print_status "error" "Terraform configuration validation failed"
    exit 1
fi

# Determine environment and region
ENVIRONMENT=${ENVIRONMENT:-"dev"}
REGION=${AWS_REGION:-"us-east-1"}
TFVARS_FILE="../environments/livekit-poc/$REGION/$ENVIRONMENT/inputs.tfvars"

if [ ! -f "$TFVARS_FILE" ]; then
    print_status "error" "Terraform variables file not found: $TFVARS_FILE"
    exit 1
fi

print_status "info" "Using environment: $ENVIRONMENT"
print_status "info" "Using region: $REGION"
print_status "info" "Using tfvars file: $TFVARS_FILE"

# Create Terraform plan
print_status "info" "📋 Creating Terraform plan..."

# Add deployment role ARN if provided
TERRAFORM_VARS="-var-file=$TFVARS_FILE"
if [ -n "$DEPLOYMENT_ROLE_ARN" ]; then
    print_status "info" "Using deployment role: $DEPLOYMENT_ROLE_ARN"
    TERRAFORM_VARS="$TERRAFORM_VARS -var=deployment_role_arn=$DEPLOYMENT_ROLE_ARN"
fi

if terraform plan $TERRAFORM_VARS -out=tfplan -detailed-exitcode; then
    PLAN_EXIT_CODE=$?
    case $PLAN_EXIT_CODE in
        0)
            print_status "info" "No changes detected in Terraform plan"
            ;;
        2)
            print_status "success" "Terraform plan created successfully with changes"
            ;;
        *)
            print_status "error" "Terraform plan failed with exit code: $PLAN_EXIT_CODE"
            exit 1
            ;;
    esac
else
    print_status "error" "Failed to create Terraform plan"
    exit 1
fi

# Ask for confirmation if not in automation
if [ -z "$TF_AUTO_APPROVE" ] && [ -z "$CI" ]; then
    echo ""
    print_status "warning" "⚠️  This will create AWS resources that may incur costs!"
    print_status "info" "Resources to be created:"
    echo "   - EKS Cluster with node groups"
    echo "   - VPC with public/private subnets"
    echo "   - ElastiCache Redis cluster"
    echo "   - Security groups and networking"
    echo ""
    read -p "Do you want to proceed with the deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "info" "Deployment cancelled by user"
        exit 0
    fi
fi

# Apply Terraform plan
print_status "info" "🏗️  Applying Terraform deployment..."
if retry_command 2 10 "terraform apply -auto-approve tfplan"; then
    print_status "success" "Infrastructure deployed successfully!"
else
    print_status "error" "Failed to apply Terraform plan"
    exit 1
fi

# Get outputs with error handling
print_status "info" "📊 Retrieving deployment information..."

CLUSTER_NAME=""
REDIS_ENDPOINT=""
VPC_ID=""

if terraform output cluster_name >/dev/null 2>&1; then
    CLUSTER_NAME=$(terraform output -raw cluster_name)
    print_status "success" "Cluster Name: $CLUSTER_NAME"
else
    print_status "warning" "Could not retrieve cluster name"
fi

if terraform output redis_cluster_endpoint >/dev/null 2>&1; then
    REDIS_ENDPOINT=$(terraform output -raw redis_cluster_endpoint)
    print_status "success" "Redis Endpoint: $REDIS_ENDPOINT"
else
    print_status "warning" "Could not retrieve Redis endpoint"
fi

if terraform output vpc_id >/dev/null 2>&1; then
    VPC_ID=$(terraform output -raw vpc_id)
    print_status "success" "VPC ID: $VPC_ID"
else
    print_status "warning" "Could not retrieve VPC ID"
fi

# Configure kubectl if cluster was created
if [ -n "$CLUSTER_NAME" ]; then
    print_status "info" "🔧 Configuring kubectl..."
    if retry_command 3 5 "aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME"; then
        print_status "success" "kubectl configured successfully"
        
        # Verify cluster access
        print_status "info" "🔍 Verifying cluster access..."
        if kubectl get nodes >/dev/null 2>&1; then
            print_status "success" "Cluster is accessible"
            kubectl get nodes
        else
            print_status "warning" "Cluster created but not yet accessible (this is normal, may take a few minutes)"
        fi
    else
        print_status "warning" "Failed to configure kubectl (cluster may still be initializing)"
    fi
fi

# Save deployment info to file
DEPLOYMENT_INFO_FILE="deployment-info.json"
cat > "$DEPLOYMENT_INFO_FILE" << EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "environment": "$ENVIRONMENT",
    "region": "$REGION",
    "cluster_name": "$CLUSTER_NAME",
    "redis_endpoint": "$REDIS_ENDPOINT",
    "vpc_id": "$VPC_ID"
}
EOF

print_status "success" "Deployment information saved to: $DEPLOYMENT_INFO_FILE"

print_status "success" "🎉 Infrastructure deployment complete!"
echo ""
print_status "info" "📋 Next steps:"
echo "   1. Run ./02-setup-load-balancer.sh to install AWS Load Balancer Controller"
echo "   2. Run ./03-deploy-livekit.sh to deploy LiveKit"
echo ""
print_status "info" "💡 Useful commands:"
echo "   - Check cluster status: kubectl get nodes"
echo "   - View all resources: kubectl get all --all-namespaces"
echo "   - Check Terraform outputs: terraform output"