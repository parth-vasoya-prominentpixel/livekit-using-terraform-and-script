# LiveKit Deployment Troubleshooting Guide

This guide covers common issues and solutions for LiveKit deployment on EKS.

## Quick Diagnostics

Run the test script to get an overview:
```bash
chmod +x scripts/test-livekit-deployment.sh
./scripts/test-livekit-deployment.sh
```

## Common Issues and Solutions

### 1. TLS Secret Not Found Error

**Error**: `secret "aws-load-balancer-tls" not found`

**Solution**: This error is now fixed. AWS Load Balancer Controller uses ACM certificates for TLS termination, not Kubernetes secrets.

**Verification**:
```bash
# Check if AWS Load Balancer Controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### 2. LiveKit Readiness Probe Failing

**Error**: `dial tcp 10.0.x.x:7880: connect: connection refused`

**Solution**: Fixed by using proper LiveKit health check endpoint `/rtc/validate` and increased delays.

**Verification**:
```bash
# Check pod status
kubectl get pods -n livekit -l app.kubernetes.io/name=livekit-server

# Check pod events
kubectl describe pods -n livekit -l app.kubernetes.io/name=livekit-server
```

### 3. ALB Ingress Not Getting External IP

**Error**: Ingress shows no ADDRESS field

**Possible Causes**:
- AWS Load Balancer Controller not installed
- Incorrect Ingress annotations
- IAM permissions issues

**Solutions**:
```bash
# 1. Check AWS Load Balancer Controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 2. Check Ingress status
kubectl describe ingress -n livekit

# 3. Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 4. Reinstall Load Balancer Controller if needed
./scripts/02-setup-load-balancer.sh
```

### 4. Redis Connection Issues

**Error**: LiveKit cannot connect to Redis

**Solutions**:
```bash
# 1. Verify Redis endpoint
cd resources
terraform output redis_cluster_endpoint

# 2. Check security groups allow EKS access
kubectl get pods -n livekit -o wide

# 3. Test Redis connectivity from a pod
kubectl run redis-test --image=redis:alpine -it --rm -- redis-cli -h <redis-endpoint> ping
```

### 5. Pod Stuck in Pending State

**Possible Causes**:
- Insufficient node capacity
- Resource constraints
- Node selector issues

**Solutions**:
```bash
# Check node status
kubectl get nodes

# Check pod events
kubectl describe pods -n livekit -l app.kubernetes.io/name=livekit-server

# Check resource usage
kubectl top nodes
kubectl top pods -n livekit
```

### 6. Certificate Issues

**Error**: SSL/TLS certificate problems

**Solutions**:
```bash
# 1. Check available ACM certificates
aws acm list-certificates --region us-east-1

# 2. Verify certificate status
aws acm describe-certificate --certificate-arn <cert-arn> --region us-east-1

# 3. Check Ingress annotations
kubectl get ingress -n livekit -o yaml
```

## Useful Commands

### Monitoring
```bash
# Watch pod status
kubectl get pods -n livekit -w

# Stream logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit-server -f

# Check resource usage
kubectl top pods -n livekit
```

### Debugging
```bash
# Get detailed pod information
kubectl describe pods -n livekit -l app.kubernetes.io/name=livekit-server

# Check service endpoints
kubectl get endpoints -n livekit

# Check Ingress details
kubectl describe ingress -n livekit

# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

### Cleanup and Restart
```bash
# Restart LiveKit deployment
kubectl rollout restart deployment -n livekit

# Delete and recreate pods
kubectl delete pods -n livekit -l app.kubernetes.io/name=livekit-server

# Reinstall LiveKit
helm uninstall livekit -n livekit
./scripts/03-deploy-livekit.sh
```

## Health Check Endpoints

LiveKit provides these health check endpoints:
- `/rtc/validate` - Main health check (used by probes)
- `/` - Basic connectivity check
- `/rtc` - RTC service status

## Expected Deployment Timeline

1. **Infrastructure (Terraform)**: 15-20 minutes
2. **Load Balancer Controller**: 3-5 minutes
3. **LiveKit Deployment**: 5-10 minutes
4. **ALB Provisioning**: 2-5 minutes

Total: ~25-40 minutes for complete deployment

## Getting Help

If issues persist:

1. Run the test script: `./scripts/test-livekit-deployment.sh`
2. Check AWS Console for ALB status
3. Review EKS cluster events in AWS Console
4. Check CloudWatch logs for detailed error messages

## Configuration Files

- `livekit.env` - Main configuration
- `scripts/03-deploy-livekit.sh` - Deployment script
- `scripts/test-livekit-deployment.sh` - Testing script
- `resources/outputs.tf` - Terraform outputs including Redis endpoint