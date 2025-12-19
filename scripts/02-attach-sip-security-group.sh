#!/bin/bash

# Attach SIP security group to existing EKS node groups
# This allows SIP traffic (port 5060) from Twilio CIDRs only

set -e

# Load cluster info
CLUSTER_INFO_FILE="../terraform-cluster-info.json"
if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    echo "❌ Cluster info file not found. Run 01-create-eks-cluster.sh first."
    exit 1
fi

CLUSTER_NAME=$(jq -r '.cluster_name' $CLUSTER_INFO_FILE)
REGION=$(jq -r '.region' $CLUSTER_INFO_FILE)

echo "🔒 Attaching SIP security group to EKS node groups..."
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $REGION"

# Get SIP security group ID from Terraform output
SIP_SG_ID=$(cd ../resources && terraform output -raw sip_security_group_id)

if [ -z "$SIP_SG_ID" ]; then
    echo "❌ SIP security group not found. Run terraform apply first."
    exit 1
fi

echo "   SIP Security Group: $SIP_SG_ID"

# Get node group names
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION --query 'nodegroups' --output text)

for NODE_GROUP in $NODE_GROUPS; do
    echo "🔧 Processing node group: $NODE_GROUP"
    
    # Get Auto Scaling Group name
    ASG_NAME=$(aws eks describe-nodegroup \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $NODE_GROUP \
        --region $REGION \
        --query 'nodegroup.resources.autoScalingGroups[0].name' \
        --output text)
    
    if [ "$ASG_NAME" != "None" ] && [ -n "$ASG_NAME" ]; then
        echo "   Auto Scaling Group: $ASG_NAME"
        
        # Get launch template
        LAUNCH_TEMPLATE=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --region $REGION \
            --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateName' \
            --output text)
        
        LAUNCH_TEMPLATE_VERSION=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --region $REGION \
            --query 'AutoScalingGroups[0].LaunchTemplate.Version' \
            --output text)
        
        echo "   Launch Template: $LAUNCH_TEMPLATE (version: $LAUNCH_TEMPLATE_VERSION)"
        
        # Get current security groups
        CURRENT_SGS=$(aws ec2 describe-launch-template-versions \
            --launch-template-name $LAUNCH_TEMPLATE \
            --versions $LAUNCH_TEMPLATE_VERSION \
            --region $REGION \
            --query 'LaunchTemplateVersions[0].LaunchTemplateData.SecurityGroupIds' \
            --output text)
        
        # Add SIP security group if not already present
        if [[ "$CURRENT_SGS" != *"$SIP_SG_ID"* ]]; then
            echo "   Adding SIP security group to launch template..."
            
            # Create new launch template version with SIP security group
            NEW_SGS="$CURRENT_SGS $SIP_SG_ID"
            
            aws ec2 create-launch-template-version \
                --launch-template-name $LAUNCH_TEMPLATE \
                --source-version $LAUNCH_TEMPLATE_VERSION \
                --launch-template-data "{\"SecurityGroupIds\":[$(echo $NEW_SGS | tr ' ' ',' | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]}}" \
                --region $REGION
            
            echo "   ✅ SIP security group added to $NODE_GROUP"
        else
            echo "   ✅ SIP security group already attached to $NODE_GROUP"
        fi
    else
        echo "   ⚠️  No Auto Scaling Group found for $NODE_GROUP"
    fi
done

echo "✅ SIP security group attachment completed!"
echo "🎯 Port 5060 (TCP/UDP) is now accessible from Twilio CIDRs only"