#!/bin/bash

# Enhanced script to check and install prerequisites with retry logic
set -e

echo "🔍 Checking and installing prerequisites for LiveKit EKS deployment..."

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

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to retry command with exponential backoff
retry_command() {
    local max_attempts=$1
    local delay=$2
    local command="${@:3}"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_status "info" "Attempt $attempt/$max_attempts: $command"
        
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
            delay=$((delay * 2))  # Exponential backoff
            attempt=$((attempt + 1))
        fi
    done
}

# Function to install tool if not exists
install_if_missing() {
    local tool=$1
    local install_cmd=$2
    local check_cmd=${3:-"$tool --version"}
    
    if command_exists "$tool"; then
        local version_output=$(eval "$check_cmd" 2>/dev/null || echo "version unknown")
        print_status "success" "$tool is already installed: $version_output"
        return 0
    fi
    
    print_status "warning" "$tool not found, installing..."
    
    if retry_command 3 2 "$install_cmd"; then
        if command_exists "$tool"; then
            local version_output=$(eval "$check_cmd" 2>/dev/null || echo "version unknown")
            print_status "success" "$tool installed successfully: $version_output"
        else
            print_status "error" "$tool installation completed but command not found"
            return 1
        fi
    else
        print_status "error" "Failed to install $tool"
        return 1
    fi
}

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    OS="windows"
fi

print_status "info" "Detected OS: $OS"

# Install prerequisites based on OS
case $OS in
    "linux")
        # Update package manager
        if command_exists apt-get; then
            print_status "info" "Updating package manager..."
            retry_command 3 5 "sudo apt-get update -qq"
        fi
        
        # Install basic tools
        install_if_missing "curl" "sudo apt-get install -y curl"
        install_if_missing "wget" "sudo apt-get install -y wget"
        install_if_missing "unzip" "sudo apt-get install -y unzip"
        install_if_missing "jq" "sudo apt-get install -y jq"
        
        # Install AWS CLI
        install_if_missing "aws" "curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip" "aws --version"
        
        # Install Terraform
        TERRAFORM_VERSION="1.14.2"
        install_if_missing "terraform" "wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && unzip -q terraform_${TERRAFORM_VERSION}_linux_amd64.zip && sudo mv terraform /usr/local/bin/ && rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip" "terraform version"
        
        # Install kubectl
        KUBECTL_VERSION="v1.32.0"
        install_if_missing "kubectl" "curl -LO 'https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl' && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl" "kubectl version --client"
        
        # Install Helm
        HELM_VERSION="v3.19.2"
        install_if_missing "helm" "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -xz && sudo mv linux-amd64/helm /usr/local/bin/ && rm -rf linux-amd64" "helm version"
        
        # Install eksctl
        EKSCTL_VERSION="0.197.0"
        install_if_missing "eksctl" "curl -sLO 'https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}/eksctl_Linux_amd64.tar.gz' && tar -xzf eksctl_Linux_amd64.tar.gz && sudo mv eksctl /usr/local/bin/ && rm eksctl_Linux_amd64.tar.gz" "eksctl version"
        ;;
        
    "macos")
        # Install Homebrew if not exists
        if ! command_exists brew; then
            print_status "warning" "Homebrew not found, installing..."
            retry_command 3 5 '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        fi
        
        # Install tools via Homebrew
        install_if_missing "aws" "brew install awscli"
        install_if_missing "terraform" "brew install terraform"
        install_if_missing "kubectl" "brew install kubectl"
        install_if_missing "helm" "brew install helm"
        install_if_missing "eksctl" "brew install eksctl"
        install_if_missing "jq" "brew install jq"
        ;;
        
    "windows")
        print_status "error" "Windows installation not fully automated. Please install tools manually:"
        echo "   - AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo "   - Terraform: https://learn.hashicorp.com/tutorials/terraform/install-cli"
        echo "   - kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/"
        echo "   - Helm: https://helm.sh/docs/intro/install/"
        echo "   - eksctl: https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html"
        echo "   - jq: https://stedolan.github.io/jq/download/"
        exit 1
        ;;
        
    *)
        print_status "error" "Unsupported OS: $OSTYPE"
        exit 1
        ;;
esac

# Verify all tools are installed
print_status "info" "Verifying all tools are installed..."

TOOLS=("aws" "terraform" "kubectl" "helm" "eksctl" "jq")
MISSING_TOOLS=()

for tool in "${TOOLS[@]}"; do
    if command_exists "$tool"; then
        print_status "success" "$tool is available"
    else
        print_status "error" "$tool is not available"
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    print_status "error" "Missing tools: ${MISSING_TOOLS[*]}"
    exit 1
fi

# Check AWS credentials (skip in CI/CD environments)
if [ -z "$CI" ] && [ -z "$GITHUB_ACTIONS" ]; then
    print_status "info" "Checking AWS credentials..."
    if retry_command 3 2 "aws sts get-caller-identity >/dev/null 2>&1"; then
        print_status "success" "AWS credentials are configured"
        aws sts get-caller-identity
    else
        print_status "error" "AWS credentials are not configured. Please run 'aws configure'"
        exit 1
    fi
else
    print_status "info" "Running in CI/CD environment - AWS credentials will be configured via OIDC"
fi

print_status "success" "All prerequisites are met!"
echo ""
echo "📋 Next steps:"
echo "   1. Run ./01-deploy-infrastructure.sh to deploy EKS cluster"
echo "   2. Run ./02-setup-load-balancer.sh to install AWS Load Balancer Controller"
echo "   3. Run ./03-deploy-livekit.sh to deploy LiveKit"