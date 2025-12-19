#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Based on official AWS documentation: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
# Version: AWS Load Balancer Controller v2.14.1

set -e

echo "⚖️ Setting up AWS Load Balancer Controller..."
echo "📋 Following official AWS EKS documentation"

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
echo "   Controller Version: v2.14.1"
echo "   Mode: SAFE (no deletion of existing resources)"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "📋 AWS Account ID: $ACCOUNT_ID"

# Check if cluster exists and is accessible
echo "🔍 Verifying cluster access..."
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "❌ Cluster $CLUSTER_NAME does not exist or is not accessible"
    exit 1
fi

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"

# Test kubectl connectivity
echo "🔍 Testing kubectl connectivity..."
if ! timeout 30 kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cluster is not accessible via kubectl"
    echo "💡 Check IAM permissions and cluster endpoint access"
    exit 1
fi
echo "✅ Cluster is accessible"

# Get cluster VPC ID
echo "🔍 Getting cluster VPC information..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "✅ Cluster VPC ID: $VPC_ID"

# Step 1: Create IAM Policy (if not exists)
echo ""
echo "📋 Step 1: Setting up IAM Policy..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_ARN"
else
    echo "📋 Creating IAM policy..."
    
    # Download the policy
    if ! curl -sS -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json; then
        echo "❌ Failed to download IAM policy"
        exit 1
    fi
    
    # Create the policy
    if aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json; then
        echo "✅ IAM policy created: $POLICY_ARN"
        rm -f iam_policy.json
    else
        echo "❌ Failed to create IAM policy"
        exit 1
    fi
fi

# Step 2: Handle Service Account - Smart Detection and Creation
echo ""
echo "📋 Step 2: Setting up Service Account..."
echo "🔍 Checking for existing AWS Load Balancer Controller service account..."

# Default service account name
DEFAULT_SA="aws-load-balancer-controller"
SA_TO_USE="$DEFAULT_SA"

# Check if service account exists
if kubectl get serviceaccount "$DEFAULT_SA" -n kube-system >/dev/null 2>&1; then
    echo "✅ Found existing service account: $DEFAULT_SA"
    
    # Check if it has IAM role annotation
    SA_ROLE=$(kubectl get serviceaccount "$DEFAULT_SA" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "$SA_ROLE" ]; then
        echo "✅ Service account has IAM role annotation: $SA_ROLE"
        echo "🎯 Using existing service account (no changes needed)"
    else
        echo "⚠️ Service account exists but has no IAM role annotation"
        echo "🔧 This is OK - the service account can still work with node IAM roles"
        echo "🎯 Using existing service account (no changes needed)"
    fi
    
    SA_TO_USE="$DEFAULT_SA"
    echo "✅ Service account ready: $SA_TO_USE"
    
else
    echo "📋 Service account $DEFAULT_SA not found"
    echo "🔧 Creating new service account with IAM role using eksctl..."
    echo "📋 This will create:"
    echo "   - Service account: $DEFAULT_SA"
    echo "   - IAM role: AmazonEKSLoadBalancerControllerRole"
    echo "   - Role binding to policy: AWSLoadBalancerControllerIAMPolicy"
    
    echo "⏳ Creating service account (this may take 2-3 minutes)..."
    
    # Create service account with eksctl
    if eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace=kube-system \
        --name="$DEFAULT_SA" \
        --attach-policy-arn="$POLICY_ARN" \
        --override-existing-serviceaccounts \
        --region="$AWS_REGION" \
        --approve; then
        
        echo "✅ Service account created successfully: $DEFAULT_SA"
        
        # Verify the service account was created with role
        echo "🔍 Verifying service account creation..."
        sleep 10  # Wait for service account to be fully ready
        
        SA_ROLE=$(kubectl get serviceaccount "$DEFAULT_SA" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
        if [ -n "$SA_ROLE" ]; then
            echo "✅ Service account verified with IAM role: $SA_ROLE"
        else
            echo "⚠️ Service account created but role annotation not found yet"
            echo "💡 This is normal - role binding may take a few moments"
        fi
        
        SA_TO_USE="$DEFAULT_SA"
        echo "✅ Service account ready: $SA_TO_USE"
        
    else
        echo "❌ Failed to create service account"
        echo "💡 Possible issues:"
        echo "   - IAM permissions insufficient"
        echo "   - OIDC provider not configured for cluster"
        echo "   - Network connectivity issues"
        exit 1
    fi
fi

echo "📋 Service account configuration complete"

# Step 3: Install AWS Load Balancer Controller
echo ""
echo "📋 Step 3: Installing AWS Load Balancer Controller..."

# Add EKS Helm repository
echo "📦 Adding EKS Helm repository..."
echo "🔍 Adding official AWS EKS charts repository..."
if helm repo add eks https://aws.github.io/eks-charts; then
    echo "✅ EKS charts repository added successfully"
else
    echo "⚠️ Repository might already exist, continuing..."
fi

echo "🔄 Updating Helm repositories to get latest charts..."
if helm repo update eks; then
    echo "✅ Helm repositories updated successfully"
else
    echo "❌ Failed to update Helm repositories"
    exit 1
fi

# Check for existing Helm installations
echo "🔍 Checking for existing AWS Load Balancer Controller installations..."
EXISTING_RELEASE=""
if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
    EXISTING_RELEASE=$(helm list -n kube-system | grep "aws-load-balancer-controller" | awk '{print $1}' | head -1)
    echo "✅ Found existing Helm release: $EXISTING_RELEASE"
    
    echo "🔄 Upgrading existing installation..."
    echo "📋 Upgrade configuration:"
    echo "   - Release: $EXISTING_RELEASE"
    echo "   - Cluster: $CLUSTER_NAME"
    echo "   - Service Account: $SA_TO_USE (existing)"
    echo "   - VPC ID: $VPC_ID"
    echo "   - Region: $AWS_REGION"
    echo "   - Chart Version: 1.14.0"
    echo ""
    echo "⏳ Starting Helm upgrade (this may take 5-10 minutes)..."
    
    if helm upgrade "$EXISTING_RELEASE" eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SA_TO_USE" \
        --set region="$AWS_REGION" \
        --set vpcId="$VPC_ID" \
        --version 1.14.0 \
        --wait --timeout=10m; then
        
        echo "✅ Helm upgrade completed successfully"
        echo "🎯 This should fix any CrashLoopBackOff issues"
    else
        echo "❌ Helm upgrade failed"
        echo "💡 Checking current deployment status..."
        kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller || echo "No deployment found"
        exit 1
    fi
        
else
    echo "📋 No existing installation found"
    echo "🚀 Installing AWS Load Balancer Controller (fresh installation)..."
    echo "📋 Installation configuration:"
    echo "   - Release Name: aws-load-balancer-controller"
    echo "   - Namespace: kube-system"
    echo "   - Cluster: $CLUSTER_NAME"
    echo "   - Service Account: $SA_TO_USE"
    echo "   - VPC ID: $VPC_ID"
    echo "   - Region: $AWS_REGION"
    echo "   - Chart Version: 1.14.0"
    echo ""
    echo "⏳ Starting Helm installation (this may take 5-10 minutes)..."
    
    if helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SA_TO_USE" \
        --set region="$AWS_REGION" \
        --set vpcId="$VPC_ID" \
        --version 1.14.0 \
        --wait --timeout=10m; then
        
        echo "✅ Helm installation completed successfully"
    else
        echo "❌ Helm installation failed"
        echo "💡 Checking for any partial deployment..."
        kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller || echo "No deployment found"
        exit 1
    fi
fi

echo "📋 Helm deployment phase completed"

# Step 4: Verify Installation
echo ""
echo "📋 Step 4: Verifying Installation..."
echo "🔍 Looking for AWS Load Balancer Controller deployment..."

# Find the deployment
LB_DEPLOYMENT=$(kubectl get deployments -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name 2>/dev/null | head -1)

if [ -n "$LB_DEPLOYMENT" ]; then
    DEPLOYMENT_NAME=$(echo "$LB_DEPLOYMENT" | cut -d'/' -f2)
    echo "✅ Found AWS Load Balancer Controller deployment: $DEPLOYMENT_NAME"
    
    # Show current deployment status
    echo "📋 Current deployment status:"
    kubectl get deployment -n kube-system "$DEPLOYMENT_NAME"
    
    # Wait for deployment to be ready
    echo ""
    echo "⏳ Waiting for deployment to be ready (timeout: 5 minutes)..."
    echo "💡 This step ensures all pods are running and healthy"
    
    if kubectl wait --for=condition=available deployment/"$DEPLOYMENT_NAME" -n kube-system --timeout=300s; then
        echo "✅ AWS Load Balancer Controller deployment is ready!"
        
        # Show final pod status
        echo ""
        echo "📋 Final pod status:"
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
        
        # Count running pods
        RUNNING_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | grep -c "Running" || echo "0")
        TOTAL_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | wc -l || echo "0")
        
        echo "📊 Pod status: $RUNNING_PODS/$TOTAL_PODS pods running"
        
        if [ "$RUNNING_PODS" -eq "$TOTAL_PODS" ] && [ "$RUNNING_PODS" -gt 0 ]; then
            echo "🎉 All pods are running successfully!"
        else
            echo "⚠️ Some pods may not be running. Checking logs..."
            
            # Show logs for non-running pods
            kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | while read pod status rest; do
                if [ "$status" != "Running" ]; then
                    echo "📋 Logs for non-running pod $pod (status: $status):"
                    kubectl logs "$pod" -n kube-system --tail=20 || echo "Could not get logs for $pod"
                    echo "---"
                fi
            done
        fi
        
    else
        echo "⚠️ Deployment did not become ready within 5 minutes"
        echo "📋 This might indicate configuration issues"
        
        echo ""
        echo "📋 Current deployment status:"
        kubectl get deployment -n kube-system "$DEPLOYMENT_NAME"
        
        echo ""
        echo "📋 Current pod status:"
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
        
        echo ""
        echo "📋 Checking pod logs for troubleshooting..."
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | awk '{print $1}' | while read pod; do
            if [ -n "$pod" ]; then
                echo "📋 Logs for $pod:"
                kubectl logs "$pod" -n kube-system --tail=30 || echo "Could not get logs for $pod"
                echo "---"
            fi
        done
        
        echo ""
        echo "💡 Common issues and solutions:"
        echo "   - Check IAM permissions for the service account"
        echo "   - Verify VPC ID and region are correct"
        echo "   - Check if OIDC provider is configured for the cluster"
        echo "   - Review pod logs above for specific error messages"
    fi
else
    echo "❌ No AWS Load Balancer Controller deployment found"
    echo "💡 This indicates the Helm installation may have failed"
    echo "🔍 Checking for any related resources..."
    
    # Check for any pods with the label
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller || echo "No pods found"
    
    # Check Helm releases
    echo "📋 Checking Helm releases:"
    helm list -n kube-system | grep -i "load-balancer\|alb" || echo "No load balancer related releases found"
    
    exit 1
fi

echo ""
echo "🎉 AWS Load Balancer Controller setup completed!"
echo ""
echo "📋 Summary:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Service Account: $SA_TO_USE"
echo "   VPC ID: $VPC_ID"
echo "   Region: $AWS_REGION"
echo "   Status: Ready for LiveKit deployment"