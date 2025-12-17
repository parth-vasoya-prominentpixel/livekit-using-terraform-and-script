#!/bin/bash

# Cleanup script to destroy all resources
set -e

echo "🧹 LiveKit EKS Cleanup"
echo "====================="

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Warning
echo "⚠️  WARNING: This will destroy ALL resources including:"
echo "   - EKS Cluster and Node Groups"
echo "   - VPC and all networking components"
echo "   - ElastiCache Redis cluster"
echo "   - Load balancers and ingress resources"
echo ""
read -p "🤔 Are you sure you want to proceed? Type 'yes' to confirm: " -r
if [[ ! $REPLY == "yes" ]]; then
    echo "❌ Cleanup cancelled."
    exit 1
fi

# Step 1: Delete LiveKit deployment
echo "🗑️  Deleting LiveKit deployment..."
kubectl delete namespace livekit --ignore-not-found=true || echo "Namespace already deleted"

# Step 2: Delete AWS Load Balancer Controller
echo "🗑️  Deleting AWS Load Balancer Controller..."
helm uninstall aws-load-balancer-controller -n kube-system || echo "Controller already deleted"

# Step 3: Delete IAM service account
echo "🗑️  Deleting IAM service account..."
eksctl delete iamserviceaccount \
  --cluster=$(cd "$SCRIPT_DIR/../resources" && terraform output -raw cluster_name 2>/dev/null || echo "unknown") \
  --namespace=kube-system \
  --name=aws-load-balancer-controller || echo "Service account already deleted"

# Step 4: Destroy Terraform infrastructure
echo "🗑️  Destroying Terraform infrastructure..."
cd "$SCRIPT_DIR/../resources"

# Add deployment role ARN if provided
TERRAFORM_VARS="-var-file=../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
if [ -n "$DEPLOYMENT_ROLE_ARN" ]; then
    echo "🔐 Using deployment role: $DEPLOYMENT_ROLE_ARN"
    TERRAFORM_VARS="$TERRAFORM_VARS -var=deployment_role_arn=$DEPLOYMENT_ROLE_ARN"
fi

terraform destroy $TERRAFORM_VARS -auto-approve

echo "✅ Cleanup complete!"
echo "📝 Note: You may need to manually delete:"
echo "   - IAM policy: AWSLoadBalancerControllerIAMPolicy"
echo "   - IAM role: AmazonEKSLoadBalancerControllerRole"