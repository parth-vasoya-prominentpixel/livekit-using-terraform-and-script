#!/bin/bash

# Check LiveKit Helm Chart Versions
# This script helps identify available LiveKit chart versions

set -e

echo "🔍 LiveKit Chart Version Checker"
echo "================================"

# Add LiveKit repo if not already added
echo "📦 Setting up LiveKit Helm repository..."
helm repo add livekit https://helm.livekit.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

echo "✅ Repository updated"

# Check available versions
echo ""
echo "📋 Available LiveKit Chart Versions:"
echo "===================================="

if command -v jq >/dev/null 2>&1; then
    # Use jq for better formatting if available
    helm search repo livekit/livekit-server --versions --output json 2>/dev/null | jq -r '.[] | "\(.version) - \(.app_version) (\(.description))"' | head -10
else
    # Fallback to basic output
    helm search repo livekit/livekit-server --versions | head -10
fi

echo ""
echo "📋 Latest Version:"
LATEST_VERSION=$(helm search repo livekit/livekit-server --output json 2>/dev/null | jq -r '.[0].version' 2>/dev/null || echo "Unable to detect")
echo "   $LATEST_VERSION"

echo ""
echo "💡 Usage:"
echo "   Use the version number in your deployment script"
echo "   Example: CHART_VERSION=\"$LATEST_VERSION\""