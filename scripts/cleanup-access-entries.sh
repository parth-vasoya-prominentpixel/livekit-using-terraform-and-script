#!/bin/bash

# Script to clean up EKS access entries before Terraform deployment
# This prevents conflicts when Terraform tries to manage access entries

set -e

echo "🧹 Cleaning up EKS access entries..."

# Check if CLUSTER_NAME is provided
if [ -z "$CLUSTER_NAME" ]; then
    echo "❌ CLUSTER_NAME environment variable is required"
    echo "Usage: CLUSTER_NAME=your-cluster-name ./cleanup-access-entries.sh"
    exit 1
fi

# Set AWS region (default to us-east-1 if not set)
AWS_REGION=${AWS_REGION:-us-east-1}

echo "📋 Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region:  $AWS_REGION"

# Check if cluster exists
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ℹ️ Cluster $CLUSTER_NAME does not exist, nothing to clean up"
    exit 0
fi

echo "✅ Cluster $CLUSTER_NAME exists"

# List all access entries
echo "🔍 Listing existing access entries..."
ACCESS_ENTRIES=$(aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'accessEntries[]' --output text 2>/dev/null || echo "")

if [ -z "$ACCESS_ENTRIES" ] || [ "$ACCESS_ENTRIES" = "None" ]; then
    echo "ℹ️ No access entries found to clean up"
    exit 0
fi

echo "🗑️ Found access entries to clean up:"
echo "$ACCESS_ENTRIES"

# Delete each access entry
DELETED_COUNT=0
echo "$ACCESS_ENTRIES" | while IFS= read -r entry; do
    if [ -n "$entry" ] && [ "$entry" != "None" ]; then
        echo "🗑️ Deleting access entry: $entry"
        if aws eks delete-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$entry" --region "$AWS_REGION" 2>/dev/null; then
            echo "✅ Successfully deleted: $entry"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        else
            echo "⚠️ Failed to delete or already deleted: $entry"
        fi
        sleep 2
    fi
done

echo "✅ Access entry cleanup completed"
echo "📊 Processed entries, waiting for AWS to sync..."
sleep 10

# Verify cleanup
REMAINING_ENTRIES=$(aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'accessEntries[]' --output text 2>/dev/null || echo "")

if [ -z "$REMAINING_ENTRIES" ] || [ "$REMAINING_ENTRIES" = "None" ]; then
    echo "🎉 All access entries successfully cleaned up!"
else
    echo "⚠️ Some access entries may still exist:"
    echo "$REMAINING_ENTRIES"
    echo "This is normal if they are managed by other systems"
fi