#!/bin/bash

# LiveKit Deployment Test Script
# Quick verification of LiveKit deployment status

set -e

echo "🧪 LiveKit Deployment Test"
echo "=========================="

# Load configuration
CONFIG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

for config in "$ROOT_DIR/livekit.env" "$SCRIPT_DIR/livekit.env" "./livekit.env"; do
    if [ -f "$config" ]; then
        CONFIG_FILE="$config"
        break
    fi
done

if [ -z "$CONFIG_FILE" ]; then
    echo "❌ Configuration file not found: livekit.env"
    exit 1
fi

source "$CONFIG_FILE"

echo "📋 Testing environment: $NAMESPACE"
echo ""

# Test 1: Check if namespace exists
echo "🔍 Test 1: Namespace"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace exists: $NAMESPACE"
else
    echo "❌ Namespace not found: $NAMESPACE"
    exit 1
fi

# Test 2: Check LiveKit pods
echo ""
echo "🔍 Test 2: LiveKit Pods"
PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$PODS" -gt 0 ]; then
    echo "✅ Found $PODS LiveKit pod(s)"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server
    
    # Check pod status
    READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    echo "📊 Running pods: $READY_PODS/$PODS"
else
    echo "❌ No LiveKit pods found"
    exit 1
fi

# Test 3: Check service
echo ""
echo "🔍 Test 3: LiveKit Service"
if kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server >/dev/null 2>&1; then
    echo "✅ LiveKit service exists"
    kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server
else
    echo "❌ LiveKit service not found"
fi

# Test 4: Check ingress
echo ""
echo "🔍 Test 4: ALB Ingress"
if kubectl get ingress -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Ingress exists"
    kubectl get ingress -n "$NAMESPACE"
    
    # Check if ALB endpoint is ready
    ALB_ENDPOINT=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_ENDPOINT" ] && [ "$ALB_ENDPOINT" != "null" ]; then
        echo "✅ ALB endpoint ready: $ALB_ENDPOINT"
    else
        echo "⏳ ALB endpoint still provisioning"
    fi
else
    echo "❌ Ingress not found"
fi

# Test 5: Check AWS Load Balancer Controller
echo ""
echo "🔍 Test 5: AWS Load Balancer Controller"
LB_CONTROLLER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$LB_CONTROLLER_PODS" -gt 0 ]; then
    echo "✅ AWS Load Balancer Controller running ($LB_CONTROLLER_PODS pods)"
else
    echo "❌ AWS Load Balancer Controller not found"
fi

# Test 6: Check Redis connectivity (if possible)
echo ""
echo "🔍 Test 6: Redis Connectivity"
TERRAFORM_DIR="$ROOT_DIR/resources"
if [ -d "$TERRAFORM_DIR" ]; then
    cd "$TERRAFORM_DIR"
    REDIS_ENDPOINT=$(terraform output -raw redis_cluster_endpoint 2>/dev/null || echo "")
    if [ -n "$REDIS_ENDPOINT" ] && [ "$REDIS_ENDPOINT" != "null" ]; then
        echo "✅ Redis endpoint available: $REDIS_ENDPOINT"
    else
        echo "⚠️ Redis endpoint not available from Terraform"
    fi
    cd "$ROOT_DIR"
else
    echo "⚠️ Terraform directory not found"
fi

# Test 7: Check pod logs for errors
echo ""
echo "🔍 Test 7: Pod Health Check"
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=livekit-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD_NAME" ]; then
    echo "📋 Checking logs for pod: $POD_NAME"
    
    # Check for common error patterns
    ERROR_COUNT=$(kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=50 2>/dev/null | grep -i "error\|failed\|panic" | wc -l || echo "0")
    if [ "$ERROR_COUNT" -eq 0 ]; then
        echo "✅ No errors found in recent logs"
    else
        echo "⚠️ Found $ERROR_COUNT potential errors in logs"
        echo "💡 Check logs: kubectl logs -n $NAMESPACE $POD_NAME"
    fi
    
    # Show last few log lines
    echo ""
    echo "📋 Recent log entries:"
    kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=5 2>/dev/null || echo "Could not retrieve logs"
else
    echo "⚠️ No pod found to check logs"
fi

echo ""
echo "🎉 Test Summary"
echo "==============="
echo "📊 LiveKit pods: $PODS"
echo "📊 Running pods: $READY_PODS"
echo "📊 Load Balancer Controller: $LB_CONTROLLER_PODS pods"
if [ -n "$ALB_ENDPOINT" ] && [ "$ALB_ENDPOINT" != "null" ]; then
    echo "📊 ALB endpoint: $ALB_ENDPOINT"
else
    echo "📊 ALB endpoint: Still provisioning"
fi

echo ""
echo "💡 Useful commands:"
echo "   - Check pods: kubectl get pods -n $NAMESPACE"
echo "   - Check logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=livekit-server"
echo "   - Check ingress: kubectl get ingress -n $NAMESPACE"
echo "   - Describe ingress: kubectl describe ingress -n $NAMESPACE"

echo ""
echo "✅ Test completed!"