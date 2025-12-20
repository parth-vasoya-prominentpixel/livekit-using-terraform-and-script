#!/bin/bash

# AWS Load Balancer Controller Setup Script
# Based on official AWS documentation: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
# Version: AWS Load Balancer Controller v2.8.0 (stable)

set -e

echo "⚖️ Setting up AWS Load Balancer Controller..."
echo "📋 Following official AWS EKS documentation"
echo "🔗 Reference: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html"

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
echo "   Controller Version: v2.8.0 (stable)"
echo "   Documentation: Official AWS EKS User Guide"

# Get AWS account ID
echo "🔍 Getting AWS account information..."
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo "❌ Failed to get AWS account ID. Check AWS credentials."
    exit 1
fi
echo "📋 AWS Account ID: $ACCOUNT_ID"

# Check if cluster exists and is accessible
echo "🔍 Verifying cluster exists and is accessible..."
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "❌ Cluster $CLUSTER_NAME does not exist or is not accessible in region $AWS_REGION"
    echo "💡 Verify cluster name and region, and check IAM permissions"
    exit 1
fi

# Get cluster status
CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text)
echo "📋 Cluster status: $CLUSTER_STATUS"

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
    echo "❌ Cluster is not in ACTIVE state. Current state: $CLUSTER_STATUS"
    echo "💡 Wait for cluster to be ACTIVE before proceeding"
    exit 1
fi

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
if ! aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"; then
    echo "❌ Failed to update kubeconfig"
    exit 1
fi

# Test kubectl connectivity with retries
echo "🔍 Testing kubectl connectivity..."
KUBECTL_RETRIES=3
KUBECTL_SUCCESS=false

for i in $(seq 1 $KUBECTL_RETRIES); do
    echo "   Attempt $i/$KUBECTL_RETRIES..."
    if timeout 30 kubectl get nodes >/dev/null 2>&1; then
        KUBECTL_SUCCESS=true
        break
    fi
    if [ $i -lt $KUBECTL_RETRIES ]; then
        echo "   Retrying in 10 seconds..."
        sleep 10
    fi
done

if [ "$KUBECTL_SUCCESS" = false ]; then
    echo "❌ Cluster is not accessible via kubectl after $KUBECTL_RETRIES attempts"
    echo "💡 Check IAM permissions and cluster endpoint access"
    exit 1
fi
echo "✅ Cluster is accessible via kubectl"

# Get cluster VPC ID
echo "🔍 Getting cluster VPC information..."
if ! VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text); then
    echo "❌ Failed to get cluster VPC ID"
    exit 1
fi
echo "✅ Cluster VPC ID: $VPC_ID"

# Check if OIDC provider exists
echo "🔍 Checking OIDC identity provider..."
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.identity.oidc.issuer' --output text)
OIDC_ID=$(echo "$OIDC_ISSUER" | cut -d '/' -f 5)

if aws iam list-open-id-connect-providers | grep -q "$OIDC_ID"; then
    echo "✅ OIDC identity provider exists"
else
    echo "⚠️ OIDC identity provider not found"
    echo "💡 Creating OIDC identity provider..."
    
    if eksctl utils associate-iam-oidc-provider --cluster="$CLUSTER_NAME" --region="$AWS_REGION" --approve; then
        echo "✅ OIDC identity provider created successfully"
    else
        echo "❌ Failed to create OIDC identity provider"
        exit 1
    fi
fi

# Step 1: Create IAM Policy (following official docs exactly)
echo ""
echo "📋 Step 1: Setting up IAM Policy (Official AWS Documentation)"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

echo "🔍 Checking if IAM policy exists..."
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "✅ IAM policy already exists: $POLICY_ARN"
    
    # Check policy version and update if needed
    echo "🔍 Checking policy version..."
    POLICY_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
    echo "📋 Current policy version: $POLICY_VERSION"
    
else
    echo "📋 Creating IAM policy from official AWS documentation..."
    
    # Download the official policy document
    echo "📥 Downloading official IAM policy document..."
    if ! curl -sS -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json; then
        echo "❌ Failed to download IAM policy from official source"
        exit 1
    fi
    
    # Verify the downloaded file
    if [ ! -s iam_policy.json ]; then
        echo "❌ Downloaded policy file is empty"
        exit 1
    fi
    
    echo "📋 Creating IAM policy: $POLICY_NAME"
    if aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --description "IAM policy for AWS Load Balancer Controller"; then
        echo "✅ IAM policy created successfully: $POLICY_ARN"
    else
        echo "❌ Failed to create IAM policy"
        exit 1
    fi
    
    # Clean up downloaded file
    rm -f iam_policy.json
fi

# Step 2: Create Service Account (following official docs exactly)
echo ""
echo "📋 Step 2: Setting up Service Account (Official AWS Documentation)"
SA_NAME="aws-load-balancer-controller"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"

echo "🔍 Checking for existing service account..."
if kubectl get serviceaccount "$SA_NAME" -n kube-system >/dev/null 2>&1; then
    echo "✅ Service account '$SA_NAME' already exists"
    
    # Check if it has proper IAM role annotation
    SA_ROLE=$(kubectl get serviceaccount "$SA_NAME" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "$SA_ROLE" ]; then
        echo "✅ Service account has IAM role annotation: $SA_ROLE"
        
        # Verify the role exists and has correct policy
        ROLE_NAME_FROM_ARN=$(echo "$SA_ROLE" | cut -d'/' -f2)
        if aws iam get-role --role-name "$ROLE_NAME_FROM_ARN" >/dev/null 2>&1; then
            echo "✅ IAM role exists and is accessible"
            
            # Check if policy is attached
            if aws iam list-attached-role-policies --role-name "$ROLE_NAME_FROM_ARN" | grep -q "$POLICY_NAME"; then
                echo "✅ Required policy is attached to the role"
                echo "🎯 Using existing service account configuration"
            else
                echo "⚠️ Required policy not attached to role"
                echo "🔧 Attaching policy to existing role..."
                aws iam attach-role-policy --role-name "$ROLE_NAME_FROM_ARN" --policy-arn "$POLICY_ARN"
                echo "✅ Policy attached successfully"
            fi
        else
            echo "⚠️ Referenced IAM role does not exist"
            echo "🔧 Will recreate service account with proper role"
            kubectl delete serviceaccount "$SA_NAME" -n kube-system
            SA_EXISTS=false
        fi
    else
        echo "⚠️ Service account exists but has no IAM role annotation"
        echo "🔧 Will recreate service account with proper IAM role"
        kubectl delete serviceaccount "$SA_NAME" -n kube-system
        SA_EXISTS=false
    fi
else
    SA_EXISTS=false
fi

if [ "${SA_EXISTS:-true}" = false ]; then
    echo "📋 Creating service account with IAM role using eksctl..."
    echo "📋 This will create:"
    echo "   - Service account: $SA_NAME"
    echo "   - IAM role: $ROLE_NAME"
    echo "   - Role policy attachment: $POLICY_NAME"
    
    echo "⏳ Creating service account (this may take 2-3 minutes)..."
    
    if eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace=kube-system \
        --name="$SA_NAME" \
        --role-name="$ROLE_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --override-existing-serviceaccounts \
        --region="$AWS_REGION" \
        --approve; then
        
        echo "✅ Service account created successfully"
        
        # Verify creation
        echo "🔍 Verifying service account creation..."
        sleep 15
        
        SA_ROLE=$(kubectl get serviceaccount "$SA_NAME" -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
        if [ -n "$SA_ROLE" ]; then
            echo "✅ Service account verified with IAM role: $SA_ROLE"
        else
            echo "⚠️ Service account created but role annotation not found"
            echo "💡 This may take a few moments to propagate"
        fi
        
    else
        echo "❌ Failed to create service account"
        echo "💡 Common issues:"
        echo "   - Insufficient IAM permissions"
        echo "   - OIDC provider not configured"
        echo "   - Network connectivity issues"
        exit 1
    fi
fi

# Step 3: Install AWS Load Balancer Controller (following official docs exactly)
echo ""
echo "📋 Step 3: Installing AWS Load Balancer Controller (Official AWS Documentation)"

# Add official EKS Helm repository
echo "📦 Adding official EKS Helm repository..."
if helm repo list | grep -q "^eks\s"; then
    echo "✅ EKS repository already exists"
else
    if helm repo add eks https://aws.github.io/eks-charts; then
        echo "✅ EKS repository added successfully"
    else
        echo "❌ Failed to add EKS repository"
        exit 1
    fi
fi

echo "🔄 Updating Helm repositories..."
if helm repo update; then
    echo "✅ Helm repositories updated successfully"
else
    echo "❌ Failed to update Helm repositories"
    exit 1
fi

# Check for existing installations
echo "🔍 Checking for existing AWS Load Balancer Controller installations..."
EXISTING_RELEASES=$(helm list -n kube-system -q | grep -E "(aws-load-balancer-controller|alb)" || echo "")

if [ -n "$EXISTING_RELEASES" ]; then
    echo "⚠️ Found existing load balancer controller installations:"
    echo "$EXISTING_RELEASES"
    
    for release in $EXISTING_RELEASES; do
        echo "🔍 Checking health of release: $release"
        
        # Check if deployment is healthy
        if kubectl get deployment -n kube-system -l app.kubernetes.io/instance="$release" >/dev/null 2>&1; then
            DEPLOYMENT_STATUS=$(kubectl get deployment -n kube-system -l app.kubernetes.io/instance="$release" --no-headers | awk '{print $2}' | head -1)
            READY=$(echo "$DEPLOYMENT_STATUS" | cut -d'/' -f1)
            DESIRED=$(echo "$DEPLOYMENT_STATUS" | cut -d'/' -f2)
            
            if [ "$READY" = "$DESIRED" ] && [ "$READY" != "0" ]; then
                echo "✅ Release '$release' is healthy ($READY/$DESIRED pods ready)"
                echo "🔄 Will upgrade existing installation"
                UPGRADE_RELEASE="$release"
                break
            else
                echo "⚠️ Release '$release' is unhealthy ($READY/$DESIRED pods ready)"
                echo "🗑️ Removing unhealthy release..."
                helm uninstall "$release" -n kube-system || true
                
                # Wait for cleanup
                echo "⏳ Waiting for cleanup (30 seconds)..."
                sleep 30
                
                # Force cleanup if needed
                kubectl delete deployment -n kube-system -l app.kubernetes.io/instance="$release" --ignore-not-found=true
                kubectl delete pods -n kube-system -l app.kubernetes.io/instance="$release" --ignore-not-found=true
            fi
        else
            echo "⚠️ No deployment found for release '$release'"
            echo "🗑️ Removing orphaned release..."
            helm uninstall "$release" -n kube-system || true
        fi
    done
fi

# Install or upgrade
RELEASE_NAME="${UPGRADE_RELEASE:-aws-load-balancer-controller}"
CHART_VERSION="1.8.0"  # Stable version that works well

if [ -n "$UPGRADE_RELEASE" ]; then
    echo "🔄 Upgrading existing installation: $RELEASE_NAME"
    HELM_ACTION="upgrade"
else
    echo "🚀 Installing AWS Load Balancer Controller: $RELEASE_NAME"
    HELM_ACTION="install"
fi

echo "📋 Installation configuration:"
echo "   - Release Name: $RELEASE_NAME"
echo "   - Chart Version: $CHART_VERSION"
echo "   - Namespace: kube-system"
echo "   - Cluster: $CLUSTER_NAME"
echo "   - Service Account: $SA_NAME"
echo "   - VPC ID: $VPC_ID"
echo "   - Region: $AWS_REGION"

echo "⏳ Starting Helm $HELM_ACTION (timeout: 10 minutes)..."

# Prepare Helm command
HELM_CMD="helm $HELM_ACTION $RELEASE_NAME eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=$SA_NAME \
    --set region=$AWS_REGION \
    --set vpcId=$VPC_ID \
    --version $CHART_VERSION \
    --wait --timeout=10m"

echo "📋 Executing: $HELM_CMD"

if eval "$HELM_CMD"; then
    echo "✅ Helm $HELM_ACTION completed successfully"
else
    echo "❌ Helm $HELM_ACTION failed"
    
    # Show troubleshooting information
    echo "📋 Troubleshooting information:"
    echo "   Helm releases:"
    helm list -n kube-system | grep -i load-balancer || echo "   No releases found"
    
    echo "   Deployments:"
    kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller || echo "   No deployments found"
    
    echo "   Pods:"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller || echo "   No pods found"
    
    echo "   Recent events:"
    kubectl get events -n kube-system --sort-by='.lastTimestamp' | tail -10
    
    exit 1
fi

# Step 4: Verify Installation (following official docs)
echo ""
echo "📋 Step 4: Verifying Installation (Official AWS Documentation)"

echo "🔍 Checking deployment status..."
if ! kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
    echo "❌ AWS Load Balancer Controller deployment not found"
    exit 1
fi

echo "✅ Deployment found, checking readiness..."
echo "⏳ Waiting for deployment to be ready (timeout: 5 minutes)..."

if kubectl wait --for=condition=available deployment/aws-load-balancer-controller -n kube-system --timeout=300s; then
    echo "✅ AWS Load Balancer Controller is ready!"
else
    echo "❌ Deployment did not become ready within timeout"
    
    echo "📋 Current status:"
    kubectl get deployment -n kube-system aws-load-balancer-controller
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
    
    echo "📋 Pod logs:"
    kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
    
    exit 1
fi

# Final verification
echo "📋 Final verification:"
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Count running pods
RUNNING_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | wc -l || echo "0")

echo "📊 Pod Status: $RUNNING_PODS/$TOTAL_PODS pods running"

if [ "$RUNNING_PODS" -eq "$TOTAL_PODS" ] && [ "$RUNNING_PODS" -gt 0 ]; then
    echo "🎉 All pods are running successfully!"
else
    echo "⚠️ Some pods may not be running properly"
    kubectl describe pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
fi

echo ""
echo "🎉 AWS Load Balancer Controller setup completed successfully!"
echo ""
echo "📋 Summary:"
echo "   ✅ Cluster: $CLUSTER_NAME (ACTIVE)"
echo "   ✅ IAM Policy: $POLICY_ARN"
echo "   ✅ Service Account: $SA_NAME (with IAM role)"
echo "   ✅ Helm Release: $RELEASE_NAME"
echo "   ✅ Controller Version: $CHART_VERSION"
echo "   ✅ VPC ID: $VPC_ID"
echo "   ✅ Region: $AWS_REGION"
echo ""
echo "📋 Next Steps:"
echo "   1. The controller is now ready to provision AWS Load Balancers"
echo "   2. Deploy applications with LoadBalancer services or ALB Ingress"
echo "   3. Monitor controller logs: kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
echo ""
echo "📖 Documentation: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html"