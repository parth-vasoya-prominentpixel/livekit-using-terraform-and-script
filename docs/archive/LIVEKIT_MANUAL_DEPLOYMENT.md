# LiveKit Manual Deployment Guide

This guide shows how to deploy LiveKit manually using Helm.

## Prerequisites

1. EKS cluster is running
2. AWS Load Balancer Controller is installed
3. Redis cluster is accessible
4. kubectl is configured

## Step 1: Add Helm Repository

```bash
helm repo add livekit https://helm.livekit.io
helm repo update
```

## Step 2: Prepare Values File

Edit `livekit-values.yaml` and replace placeholders:

- `REDIS_ENDPOINT_PLACEHOLDER` → Your Redis endpoint
- `CERTIFICATE_ARN_PLACEHOLDER` → Your SSL certificate ARN

## Step 3: Deploy LiveKit

```bash
# Create namespace
kubectl create namespace livekit

# Deploy LiveKit
helm upgrade --install livekit livekit/livekit-server \
  -n livekit \
  -f livekit-values.yaml \
  --wait --timeout=10m
```

## Step 4: Verify Deployment

```bash
# Check pods
kubectl get pods -n livekit -l app.kubernetes.io/name=livekit

# Check services
kubectl get svc -n livekit

# Check logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit
```

## Step 5: Get ALB Endpoint

```bash
kubectl get svc -n livekit livekit -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Step 6: Configure DNS

Create CNAME records:
- `livekit-eks-tf.digi-telephony.com` → ALB endpoint
- `turn-eks-tf.digi-telephony.com` → ALB endpoint

## Configuration Details

- **Repository**: https://helm.livekit.io
- **Chart**: livekit/livekit-server
- **Domain**: livekit-eks-tf.digi-telephony.com
- **TURN Domain**: turn-eks-tf.digi-telephony.com
- **Load Balancer**: ALB only (no NLB)
- **Redis**: External ElastiCache cluster
- **SSL**: AWS Certificate Manager

## Troubleshooting

```bash
# Check Helm status
helm status livekit -n livekit

# Check events
kubectl get events -n livekit --sort-by='.lastTimestamp'

# Describe pods
kubectl describe pods -n livekit

# Test Redis connectivity
kubectl exec -n livekit <pod-name> -- nc -zv <redis-host> 6379
```