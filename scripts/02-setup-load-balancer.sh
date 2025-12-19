#!/bin/bash

# Script to setup AWS Load Balancer Controller on EKS
# This script is idempotent - safe to run multiple times

echo "⚖️ Setting up AWS Load Balancer Controller..."

# Check if CLUSTER_NAME is provided
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name ./02-setup-load-balancer.sh"
    exit 1
fi

# Set AWS region (default to us-east-1 if not set)
AWS_REGION=${AWS_REGION:-us-east-1}

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region:  $AWS_REGION"

# Function to check if cluster exists
check_cluster_exists() {
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check if cluster exists
if ! check_cluster_exists; then
    echo "❌ Cluster $CLUSTER_NAME does not exist in region $AWS_REGION"
    exit 1
fi

echo "✅ Cluster $CLUSTER_NAME exists"

# Update kubeconfig with retry
echo "🔧 Updating kubeconfig..."
for i in {1..5}; do
    if aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"; then
        echo "✅ Kubeconfig updated successfully"
        break
    else
        echo "⚠️ Kubeconfig update attempt $i failed, retrying in 15 seconds..."
        sleep 15
        if [ $i -eq 5 ]; then
            echo "❌ Failed to update kubeconfig after 5 attempts"
            exit 1
        fi
    fi
done

# Test cluster connectivity with detailed logging and limited retries
echo "🔍 Testing cluster connectivity..."
echo "📋 Starting connectivity tests with detailed logging..."

# Get detailed cluster information first
echo "🔍 Gathering cluster information..."
CLUSTER_INFO=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null)
if [ $? -eq 0 ]; then
    CLUSTER_STATUS=$(echo "$CLUSTER_INFO" | jq -r '.cluster.status // "UNKNOWN"')
    CLUSTER_ENDPOINT=$(echo "$CLUSTER_INFO" | jq -r '.cluster.endpoint // "UNKNOWN"')
    CLUSTER_VERSION=$(echo "$CLUSTER_INFO" | jq -r '.cluster.version // "UNKNOWN"')
    CLUSTER_PLATFORM_VERSION=$(echo "$CLUSTER_INFO" | jq -r '.cluster.platformVersion // "UNKNOWN"')
    
    echo "📋 Cluster Details:"
    echo "   Name: $CLUSTER_NAME"
    echo "   Status: $CLUSTER_STATUS"
    echo "   Endpoint: $CLUSTER_ENDPOINT"
    echo "   K8s Version: $CLUSTER_VERSION"
    echo "   Platform Version: $CLUSTER_PLATFORM_VERSION"
    
    if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
        echo "❌ Cluster is not ACTIVE (current: $CLUSTER_STATUS)"
        echo "� Wauit for cluster to be ACTIVE before proceeding"
        exit 1
    fi
else
    echo "❌ Failed to describe cluster - check cluster name and permissions"
    exit 1
fi

# Check current AWS identity
echo "🔍 Checking AWS identity..."
AWS_IDENTITY=$(aws sts get-caller-identity 2>/dev/null)
if [ $? -eq 0 ]; then
    AWS_ACCOUNT=$(echo "$AWS_IDENTITY" | jq -r '.Account // "UNKNOWN"')
    AWS_USER_ARN=$(echo "$AWS_IDENTITY" | jq -r '.Arn // "UNKNOWN"')
    echo "📋 AWS Identity:"
    echo "   Account: $AWS_ACCOUNT"
    echo "   ARN: $AWS_USER_ARN"
else
    echo "❌ Failed to get AWS identity - check credentials"
    exit 1
fi

# Test endpoint connectivity
echo "🔍 Testing cluster endpoint connectivity..."
if [ "$CLUSTER_ENDPOINT" != "UNKNOWN" ] && [ -n "$CLUSTER_ENDPOINT" ]; then
    echo "🌐 Testing HTTPS connectivity to: $CLUSTER_ENDPOINT"
    
    # Test with curl
    CURL_OUTPUT=$(curl -k -s -w "HTTP_CODE:%{http_code};TIME:%{time_total}" --connect-timeout 15 --max-time 30 "$CLUSTER_ENDPOINT/healthz" 2>&1)
    CURL_EXIT_CODE=$?
    
    if [ $CURL_EXIT_CODE -eq 0 ]; then
        echo "✅ Endpoint is reachable via HTTPS"
        echo "📋 Response: $CURL_OUTPUT"
    else
        echo "⚠️ Endpoint connectivity test failed"
        echo "📋 Error: $CURL_OUTPUT"
        echo "💡 This might indicate network or security group issues"
    fi
else
    echo "❌ No valid cluster endpoint found"
    exit 1
fi

# Now test kubectl connectivity with limited retries
echo "🔍 Testing kubectl connectivity (max 3 attempts)..."
for i in {1..3}; do
    echo "🔄 Kubectl attempt $i/3..."
    
    # Show current kubectl context
    echo "📋 Current kubectl context:"
    kubectl config current-context 2>/dev/null || echo "   ❌ No current context set"
    
    # Show available contexts
    echo "📋 Available contexts:"
    kubectl config get-contexts 2>/dev/null || echo "   ❌ No contexts available"
    
    # Test kubectl with detailed output
    echo "🔍 Testing 'kubectl get nodes' with timeout..."
    KUBECTL_OUTPUT=$(timeout 30 kubectl get nodes -v=6 2>&1)
    KUBECTL_EXIT_CODE=$?
    
    if [ $KUBECTL_EXIT_CODE -eq 0 ]; then
        echo "✅ Cluster is accessible via kubectl!"
        NODE_COUNT=$(echo "$KUBECTL_OUTPUT" | grep -v "^NAME" | grep -c "Ready\|NotReady" || echo "0")
        echo "📊 Found $NODE_COUNT nodes:"
        echo "$KUBECTL_OUTPUT" | head -10
        break
    else
        echo "❌ kubectl failed (exit code: $KUBECTL_EXIT_CODE)"
        echo "📋 kubectl output (last 10 lines):"
        echo "$KUBECTL_OUTPUT" | tail -10
        
        if [ $i -lt 3 ]; then
            echo "⏳ Waiting 30 seconds before retry..."
            sleep 30
        else
            echo "❌ Cluster is not accessible after 3 attempts"
            echo ""
            echo "🔍 FINAL DEBUGGING INFORMATION:"
            echo "================================"
            
            # Show cluster details again
            echo "📋 Cluster Status Check:"
            aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.{Status:status,Endpoint:endpoint,CreatedAt:createdAt}' --output table 2>/dev/null || echo "   ❌ Could not describe cluster"
            
            # Show kubectl config
            echo "📋 Kubectl Configuration:"
            kubectl config view --minify 2>/dev/null || echo "   ❌ Could not view kubectl config"
            
            # Show network test
            echo "📋 Network Connectivity:"
            if [ -n "$CLUSTER_ENDPOINT" ]; then
                echo "   Testing: $CLUSTER_ENDPOINT"
                nc -zv $(echo "$CLUSTER_ENDPOINT" | sed 's|https://||' | cut -d':' -f1) 443 2>&1 || echo "   ❌ Port 443 not reachable"
            fi
            
            echo ""
            echo "💡 TROUBLESHOOTING STEPS:"
            echo "========================"
            echo "1. Check if cluster is fully created in AWS Console"
            echo "2. Verify IAM permissions for EKS access"
            echo "3. Check security groups allow HTTPS (443) access"
            echo "4. Try accessing from AWS CloudShell:"
            echo "   aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
            echo "   kubectl get nodes"
            echo ""
            exit 1
        fi
    fi
done

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "📋 AWS Account ID: $ACCOUNT_ID"

# Check if IAM policy exists, create if not
echo "📋 Checking IAM policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_ARN"
else
    echo "📋 Creating IAM policy..."
    if ! curl -sS -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json; then
        echo "❌ Failed to download IAM policy"
        exit 1
    fi
    
    if aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json; then
        echo "✅ IAM policy created: $POLICY_ARN"
    else
        echo "❌ Failed to create IAM policy"
        exit 1
    fi
fi

# Check if service account already exists and handle conflicts
echo "🔍 Checking for existing AWS Load Balancer Controller setup..."

# Use unique names to avoid conflicts with existing setup
TIMESTAMP=$(date +%s)
SA_NAME="aws-load-balancer-controller-livekit"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole-LiveKit-${TIMESTAMP}"

# Check if our specific service account exists
if kubectl get serviceaccount "$SA_NAME" -n kube-system >/dev/null 2>&1; then
    echo "✅ Our service account $SA_NAME already exists"
    
    # Check if it has the correct annotations
    SA_ROLE=$(kubectl get serviceaccount "$SA_NAME" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "$SA_ROLE" ]; then
        echo "✅ Service account has IAM role: $SA_ROLE"
        SKIP_SA_CREATION=true
    else
        echo "⚠️ Service account exists but has no IAM role annotation"
        SKIP_SA_CREATION=false
    fi
else
    echo "📋 Our service account $SA_NAME does not exist"
    SKIP_SA_CREATION=false
fi

# Check if default service account exists (from previous setup)
if kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    echo "✅ Default AWS Load Balancer Controller service account already exists"
    DEFAULT_SA_ROLE=$(kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "$DEFAULT_SA_ROLE" ]; then
        echo "✅ Default service account has IAM role: $DEFAULT_SA_ROLE"
        echo "🔄 Using existing default service account instead of creating new one"
        SA_NAME="aws-load-balancer-controller"
        SKIP_SA_CREATION=true
    fi
fi

# Create service account only if needed
if [ "$SKIP_SA_CREATION" = "false" ]; then
    echo "🔧 Creating IAM service account with unique name: $SA_NAME"
    
    # Create new service account with unique role name
    if eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace=kube-system \
        --name="$SA_NAME" \
        --role-name "$ROLE_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --approve \
        --region="$AWS_REGION"; then
        echo "✅ IAM service account created: $SA_NAME"
    else
        echo "❌ Failed to create IAM service account"
        echo "💡 Checking if we can use existing setup..."
        
        # Fallback: try to use existing default service account
        if kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
            echo "🔄 Using existing default service account as fallback"
            SA_NAME="aws-load-balancer-controller"
        else
            echo "❌ No fallback available"
            exit 1
        fi
    fi
else
    echo "✅ Using existing service account: $SA_NAME"
fi

# Add EKS Helm repository
echo "📦 Adding EKS Helm repository..."
if ! helm repo add eks https://aws.github.io/eks-charts; then
    echo "❌ Failed to add Helm repository"
    exit 1
fi

if ! helm repo update; then
    echo "❌ Failed to update Helm repositories"
    exit 1
fi

# Check if Load Balancer Controller is already installed
echo "🔍 Checking if Load Balancer Controller is installed..."
HELM_RELEASE_NAME="aws-load-balancer-controller-livekit"

# Check for existing installation (either our release or default)
if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
    EXISTING_RELEASE=$(helm list -n kube-system | grep "aws-load-balancer-controller" | awk '{print $1}' | head -1)
    echo "✅ AWS Load Balancer Controller already installed as: $EXISTING_RELEASE"
    
    if [ "$EXISTING_RELEASE" = "aws-load-balancer-controller" ]; then
        echo "🔄 Using existing default installation"
        echo "✅ Skipping Helm installation - using existing controller"
    else
        echo "🔄 Upgrading existing installation: $EXISTING_RELEASE"
        helm upgrade "$EXISTING_RELEASE" eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name="$SA_NAME" \
            --set region="$AWS_REGION" \
            --wait --timeout=5m
    fi
else
    echo "🚀 Installing AWS Load Balancer Controller with unique name: $HELM_RELEASE_NAME"
    helm install "$HELM_RELEASE_NAME" eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SA_NAME" \
        --set region="$AWS_REGION" \
        --wait --timeout=5m
fi

# Verify installation
echo "✅ Verifying AWS Load Balancer Controller installation..."

# Check for any AWS Load Balancer Controller deployment
LB_DEPLOYMENT=$(kubectl get deployments -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name 2>/dev/null | head -1)

if [ -n "$LB_DEPLOYMENT" ]; then
    DEPLOYMENT_NAME=$(echo "$LB_DEPLOYMENT" | cut -d'/' -f2)
    echo "✅ Found AWS Load Balancer Controller deployment: $DEPLOYMENT_NAME"
    
    # Show deployment status
    kubectl get deployment -n kube-system "$DEPLOYMENT_NAME"
    
    # Show pods
    echo "📋 Controller pods:"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
    
    # Check if pods are ready
    READY_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "📊 Pod status: $READY_PODS/$TOTAL_PODS pods running"
    
    if [ "$READY_PODS" -gt 0 ]; then
        echo "🎉 AWS Load Balancer Controller is running successfully!"
        echo "✅ Service account used: $SA_NAME"
        echo "✅ Cluster: $CLUSTER_NAME"
    else
        echo "⚠️ AWS Load Balancer Controller pods are not ready yet"
        echo "💡 This might be normal - pods may still be starting"
    fi
else
    echo "❌ No AWS Load Balancer Controller deployment found"
    echo "🔍 Checking for any load balancer related deployments..."
    kubectl get deployments -n kube-system | grep -i "load\|alb\|elb" || echo "No load balancer deployments found"
    exit 1
fi

echo ""
echo "📋 Summary:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Service Account: $SA_NAME"
echo "   Region: $AWS_REGION"
echo "   Status: ✅ Ready for LiveKit deployment"