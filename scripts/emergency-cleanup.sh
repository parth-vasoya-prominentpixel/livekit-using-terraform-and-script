#!/bin/bash

# Emergency cleanup - Delete specific resources by name pattern
echo "🚨 EMERGENCY CLEANUP - Deleting LiveKit Resources"
echo "================================================"

# Configuration
REGION=${AWS_REGION:-"us-east-1"}
CLUSTER_PREFIX="lp-eks-livekit"
VPC_PREFIX="lp-vpc-main"
REDIS_PREFIX="lp-ec-redis"
ENV="dev"

echo "🔧 Configuration:"
echo "   Region: $REGION"
echo "   Environment: $ENV"
echo "   Cluster Prefix: $CLUSTER_PREFIX"

# Function to print status
print_status() {
    local status=$1
    local message=$2
    case $status in
        "success") echo "✅ $message" ;;
        "error") echo "❌ $message" ;;
        "warning") echo "⚠️ $message" ;;
        "info") echo "ℹ️ $message" ;;
    esac
}

# Delete EKS Cluster
print_status "info" "🗑️ Deleting EKS cluster..."
CLUSTER_NAME="${CLUSTER_PREFIX}-use1-${ENV}"
print_status "info" "Looking for cluster: $CLUSTER_NAME"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    print_status "warning" "Found cluster: $CLUSTER_NAME"
    
    # Delete node groups
    print_status "info" "Deleting node groups..."
    NODE_GROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups[]' --output text 2>/dev/null)
    for ng in $NODE_GROUPS; do
        print_status "info" "Deleting node group: $ng"
        aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" 2>/dev/null &
    done
    
    # Delete addons
    print_status "info" "Deleting addons..."
    ADDONS=$(aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'addons[]' --output text 2>/dev/null)
    for addon in $ADDONS; do
        print_status "info" "Deleting addon: $addon"
        aws eks delete-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon" --region "$REGION" 2>/dev/null &
    done
    
    # Wait a bit for node groups to start deleting
    sleep 60
    
    # Delete cluster
    print_status "info" "Deleting cluster: $CLUSTER_NAME"
    aws eks delete-cluster --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null &
else
    print_status "info" "No cluster found with name: $CLUSTER_NAME"
fi

# Delete ElastiCache
print_status "info" "🗑️ Deleting ElastiCache cluster..."
REDIS_NAME="${REDIS_PREFIX}-use1-${ENV}"
print_status "info" "Looking for Redis cluster: $REDIS_NAME"

if aws elasticache describe-replication-groups --replication-group-id "$REDIS_NAME" --region "$REGION" >/dev/null 2>&1; then
    print_status "warning" "Found Redis cluster: $REDIS_NAME"
    aws elasticache delete-replication-group --replication-group-id "$REDIS_NAME" --region "$REGION" 2>/dev/null &
else
    print_status "info" "No Redis cluster found with name: $REDIS_NAME"
fi

# Delete VPC and related resources
print_status "info" "🗑️ Deleting VPC resources..."
VPC_NAME="${VPC_PREFIX}-use1-${ENV}"
print_status "info" "Looking for VPC with name: $VPC_NAME"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    print_status "warning" "Found VPC: $VPC_ID"
    
    # Delete NAT Gateways
    print_status "info" "Deleting NAT Gateways..."
    NAT_GWS=$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
    for nat in $NAT_GWS; do
        print_status "info" "Deleting NAT Gateway: $nat"
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" 2>/dev/null &
    done
    
    # Delete Internet Gateways
    print_status "info" "Deleting Internet Gateways..."
    IGWs=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null)
    for igw in $IGWs; do
        print_status "info" "Detaching and deleting IGW: $igw"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null &
    done
    
    # Wait for NAT gateways to be deleted
    print_status "info" "Waiting for NAT gateways to be deleted..."
    sleep 120
    
    # Delete subnets
    print_status "info" "Deleting subnets..."
    SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text 2>/dev/null)
    for subnet in $SUBNETS; do
        print_status "info" "Deleting subnet: $subnet"
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null &
    done
    
    # Delete security groups (except default)
    print_status "info" "Deleting security groups..."
    SGS=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)
    for sg in $SGS; do
        print_status "info" "Deleting security group: $sg"
        aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null &
    done
    
    # Wait for subnets to be deleted
    sleep 30
    
    # Delete VPC
    print_status "info" "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null &
else
    print_status "info" "No VPC found with name: $VPC_NAME"
fi

# Wait for all background jobs to complete
print_status "info" "⏳ Waiting for all deletion jobs to complete..."
wait

print_status "success" "🎉 Emergency cleanup completed!"
print_status "info" "📋 Verification commands:"
echo "aws eks list-clusters --region $REGION"
echo "aws elasticache describe-replication-groups --region $REGION"
echo "aws ec2 describe-vpcs --region $REGION --filters 'Name=tag:Name,Values=*lp*$ENV*'"

print_status "warning" "💰 Check AWS billing in a few hours to ensure no unexpected charges"
print_status "info" "🔍 If resources remain, check AWS Console and delete manually"