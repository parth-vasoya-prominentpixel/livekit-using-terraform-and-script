#!/bin/bash

# Create EKS cluster using eksctl
# This creates the cluster with VPC, security groups, and managed node groups

set -e

echo "🚀 Creating EKS cluster with eksctl..."

# Cluster configuration
CLUSTER_NAME="livekit-cluster-v2"
REGION="us-east-1"
K8S_VERSION="1.33"
NODE_TYPE="t3.medium"
MIN_NODES=2
MAX_NODES=3
DESIRED_NODES=3

echo "📋 Cluster Configuration:"
echo "   Name: $CLUSTER_NAME"
echo "   Region: $REGION"
echo "   Kubernetes Version: $K8S_VERSION"
echo "   Node Type: $NODE_TYPE"
echo "   Nodes: $MIN_NODES-$MAX_NODES (desired: $DESIRED_NODES)"

# Create the cluster
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --version $K8S_VERSION \
  --nodegroup-name livekit-nodes \
  --instance-types $NODE_TYPE \
  --nodes $DESIRED_NODES \
  --nodes-min $MIN_NODES \
  --nodes-max $MAX_NODES \
  --managed \
  --with-oidc \
  --ssh-access \
  --ssh-public-key ~/.ssh/id_rsa.pub \
  --enable-ssm \
  --asg-access \
  --external-dns-access \
  --full-ecr-access \
  --appmesh-access \
  --alb-ingress-access

echo "✅ EKS cluster created successfully!"

# Get cluster info
echo "📊 Cluster Information:"
eksctl get cluster --name $CLUSTER_NAME --region $REGION

# Get VPC ID for use in Terraform
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "🏠 VPC ID: $VPC_ID"

# Get security group IDs
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
echo "🔒 Cluster Security Group: $CLUSTER_SG"

# Save cluster info for Terraform
cat > ../terraform-cluster-info.json << EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "vpc_id": "$VPC_ID",
  "cluster_security_group_id": "$CLUSTER_SG",
  "region": "$REGION"
}
EOF

echo "💾 Cluster info saved to terraform-cluster-info.json"
echo "🎯 Next: Run Terraform to create Redis and additional security groups"