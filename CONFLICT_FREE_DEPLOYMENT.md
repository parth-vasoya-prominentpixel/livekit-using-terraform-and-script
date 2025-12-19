# Conflict-Free Deployment Strategy

This document explains how all scripts are designed to avoid conflicts with your existing manual EKS setup.

## 🎯 Three-Tier Approach

All scripts follow the same pattern to ensure your manual setup remains untouched:

### 1️⃣ **First Check: Use Existing Resources**
- Check if required resources already exist
- If properly configured, use them as-is
- No modifications to existing resources

### 2️⃣ **Second Option: Create with Unique Names**
- If conflicts detected, use unique names with timestamps
- Ensures no interference with existing setup
- Clear naming convention for identification

### 3️⃣ **Third Fallback: Skip or Alternative**
- If all else fails, skip creation or use alternatives
- Graceful degradation without breaking existing setup
- Clear messaging about what's being used

## 📋 Script-by-Script Implementation

### **Load Balancer Controller Script** (`02-setup-load-balancer.sh`)

**1st Check**: Existing service account `aws-load-balancer-controller`
- ✅ If exists and configured → Use it
- ✅ If exists but not configured → Use it anyway (safer)

**2nd Option**: Create unique resources
- Service Account: `aws-load-balancer-controller-livekit`
- IAM Role: `AmazonEKSLoadBalancerControllerRole-LiveKit-{timestamp}`
- Helm Release: `aws-load-balancer-controller-livekit`

**3rd Fallback**: Skip Helm installation if controller already running
- Detects any AWS Load Balancer Controller deployment
- Uses existing controller regardless of how it was installed

### **LiveKit Deployment Script** (`03-deploy-livekit.sh`)

**1st Check**: Existing namespace `livekit`
- ✅ If empty → Use it
- ✅ If has LiveKit deployment → Create unique namespace

**2nd Option**: Create unique resources
- Namespace: `livekit-terraform-{timestamp}`
- Helm Release: `livekit-terraform-{timestamp}` (if needed)

**3rd Fallback**: Upgrade existing deployment
- If LiveKit release exists → Upgrade it
- Preserves existing configuration where possible

### **Prerequisites Script** (`00-prerequisites.sh`)
- ✅ **Read-only checks** - no resource creation
- ✅ **No conflicts possible** - only validates tools and access

## 🛡️ Protection Mechanisms

### **Namespace Isolation**
```bash
# Existing manual setup in 'livekit' namespace
kubectl get pods -n livekit

# Terraform deployment in unique namespace
kubectl get pods -n livekit-terraform-1734612345
```

### **Unique Resource Names**
```bash
# Existing manual resources
aws-load-balancer-controller
AmazonEKSLoadBalancerControllerRole

# Terraform resources (unique)
aws-load-balancer-controller-livekit
AmazonEKSLoadBalancerControllerRole-LiveKit-1734612345
```

### **Smart Detection Logic**
```bash
# Check existing before creating
if kubectl get serviceaccount aws-load-balancer-controller -n kube-system; then
    echo "Using existing service account"
else
    echo "Creating new service account with unique name"
fi
```

## 🎉 Benefits

### **For Your Manual Setup**
- ✅ **Zero Impact** - existing resources untouched
- ✅ **No Conflicts** - unique names prevent collisions
- ✅ **Preserved Configuration** - manual settings remain intact
- ✅ **Independent Operation** - both setups work simultaneously

### **For Terraform Deployment**
- ✅ **Reliable Deployment** - no dependency on manual setup
- ✅ **Clean Separation** - easy to identify Terraform resources
- ✅ **Easy Cleanup** - can remove Terraform resources without affecting manual setup
- ✅ **Predictable Behavior** - same result every time

### **For Operations**
- ✅ **Clear Identification** - easy to distinguish between manual and Terraform resources
- ✅ **Safe Experimentation** - can test without breaking existing setup
- ✅ **Rollback Safety** - can remove Terraform deployment cleanly
- ✅ **Parallel Operation** - both setups can coexist

## 📊 Resource Mapping

| Resource Type | Manual Setup | Terraform Setup | Conflict Resolution |
|---------------|--------------|-----------------|-------------------|
| **Namespace** | `livekit` | `livekit-terraform-{timestamp}` | Unique namespace |
| **Service Account** | `aws-load-balancer-controller` | `aws-load-balancer-controller-livekit` | Unique name |
| **IAM Role** | `AmazonEKSLoadBalancerControllerRole` | `AmazonEKSLoadBalancerControllerRole-LiveKit-{timestamp}` | Unique name |
| **Helm Release** | `aws-load-balancer-controller` | `aws-load-balancer-controller-livekit` | Unique name |
| **LiveKit Release** | `livekit` | `livekit-terraform-{timestamp}` | Unique name if conflict |

## 🔍 Verification Commands

### Check Both Setups Coexist
```bash
# Manual setup
kubectl get pods -n livekit
helm list -n kube-system | grep aws-load-balancer-controller

# Terraform setup
kubectl get pods -n livekit-terraform-*
helm list -n kube-system | grep aws-load-balancer-controller-livekit
```

### Identify Resources
```bash
# List all LiveKit namespaces
kubectl get namespaces | grep livekit

# List all Load Balancer Controllers
kubectl get deployments -n kube-system | grep aws-load-balancer-controller

# List all Helm releases
helm list -A | grep -E "(livekit|aws-load-balancer)"
```

## 💡 Best Practices

1. **Always run scripts in order** - prerequisites → load balancer → livekit
2. **Check existing resources first** - scripts will show what they're using
3. **Monitor both setups** - ensure no unexpected interactions
4. **Clean separation** - use different namespaces for different purposes
5. **Document changes** - keep track of what's manual vs automated

This approach ensures your manual EKS setup remains completely unaffected while allowing the Terraform deployment to work reliably alongside it.