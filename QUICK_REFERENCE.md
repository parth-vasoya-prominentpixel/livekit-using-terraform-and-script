# LiveKit EKS Quick Reference

## 🚀 Quick Start Commands

### Configure kubectl
```bash
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev
```

### Check Deployment Status
```bash
# Check all pods
kubectl get pods -A

# Check LiveKit specifically
kubectl get pods -n livekit
kubectl get services -n livekit
kubectl get ingress -n livekit

# Check Load Balancer Controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### View Logs
```bash
# LiveKit logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit -f

# Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -f
```

### Troubleshooting
```bash
# Describe problematic pods
kubectl describe pod -n livekit <pod-name>

# Check events
kubectl get events -n livekit --sort-by='.lastTimestamp'

# Check ingress details
kubectl describe ingress -n livekit
```

## 🔧 Manual Deployment Commands

### Prerequisites
```bash
./scripts/00-prerequisites.sh
```

### Infrastructure
```bash
cd resources
terraform init
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
```

### Load Balancer
```bash
./scripts/02-setup-load-balancer.sh
```

### LiveKit
```bash
./scripts/03-deploy-livekit.sh
```

## 🌐 Access URLs

- **LiveKit Server**: https://livekit-eks.digi-telephony.com
- **TURN Server**: turn-eks.livekit.digi-telephony.com:3478

## 📊 Resource Names

- **EKS Cluster**: `lp-eks-livekit-use1-dev`
- **VPC**: `lp-vpc-main-use1-dev`
- **Redis**: `lp-ec-redis-use1-dev`
- **Security Group**: `lp-sg-sip-twilio-use1-dev`

## 🔍 Monitoring Commands

```bash
# Check cluster autoscaler
kubectl get pods -n kube-system -l app=cluster-autoscaler

# Check node status
kubectl get nodes -o wide

# Check resource usage
kubectl top nodes
kubectl top pods -n livekit
```

## 🗑️ Cleanup Commands

```bash
# Delete LiveKit deployment
helm uninstall livekit -n livekit

# Delete namespace
kubectl delete namespace livekit

# Destroy infrastructure
cd resources
terraform destroy -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
```

## 🚨 Emergency Commands

### Scale Down (Cost Saving)
```bash
# Scale node group to 0
aws eks update-nodegroup-config \
  --cluster-name lp-eks-livekit-use1-dev \
  --nodegroup-name livekit_nodes \
  --scaling-config minSize=0,maxSize=10,desiredSize=0 \
  --region us-east-1
```

### Scale Up (Restore Service)
```bash
# Scale node group back up
aws eks update-nodegroup-config \
  --cluster-name lp-eks-livekit-use1-dev \
  --nodegroup-name livekit_nodes \
  --scaling-config minSize=1,maxSize=10,desiredSize=2 \
  --region us-east-1
```

### Force Pod Restart
```bash
kubectl rollout restart deployment -n livekit
```