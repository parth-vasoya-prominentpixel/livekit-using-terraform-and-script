# AWS Load Balancer Controller Setup

This document describes the AWS Load Balancer Controller setup for the LiveKit EKS deployment.

## Overview

The AWS Load Balancer Controller is a Kubernetes controller that manages AWS Elastic Load Balancers (ALB/NLB) for Kubernetes services and ingresses. It's essential for exposing LiveKit services to the internet.

## What It Does

- **Automatic ALB Creation**: Creates Application Load Balancers when you create Kubernetes Ingress resources
- **Smart Resource Management**: Handles existing IAM roles and service accounts intelligently
- **Official AWS Integration**: Uses the official AWS Load Balancer Controller Helm chart
- **OIDC Integration**: Leverages EKS OIDC provider for secure IAM role assumption

## Pipeline Integration

The load balancer controller setup is integrated as **Step 4** in the deployment pipeline:

```
Step 1: Prerequisites ✅
Step 2: Terraform Plan ✅  
Step 3: Terraform Apply ✅
Step 4: Setup Load Balancer Controller ⚖️  ← NEW STEP
Step 4.5: Test Load Balancer (Optional) 🧪  ← NEW STEP
Step 5: Deploy LiveKit 🎥
```

## Script Features

### Smart Resource Handling

The `02-setup-load-balancer.sh` script handles existing resources intelligently:

- **IAM Policy**: Uses existing `AWSLoadBalancerControllerIAMPolicy` if found, creates if missing
- **Service Account**: Reuses existing `aws-load-balancer-controller` service account with proper IAM role
- **Helm Release**: Upgrades existing installation or installs fresh
- **No Conflicts**: Designed to work with existing setups without errors

### Key Components

1. **IAM Policy**: `AWSLoadBalancerControllerIAMPolicy`
   - Permissions for ALB/NLB management
   - Downloaded from official AWS documentation

2. **IAM Role**: `AmazonEKSLoadBalancerControllerRole`
   - OIDC-enabled role for service account
   - Created via eksctl for proper integration

3. **Service Account**: `aws-load-balancer-controller`
   - Kubernetes service account in `kube-system` namespace
   - Annotated with IAM role ARN

4. **Helm Chart**: `eks/aws-load-balancer-controller`
   - Official AWS Load Balancer Controller
   - Version 1.8.1 (controller v2.8.1)

## Usage in Pipeline

The script is automatically executed in the pipeline with these environment variables:

```bash
CLUSTER_NAME="${{ needs.terraform-apply.outputs.cluster-name }}"
AWS_REGION="${{ env.AWS_REGION }}"
```

## Manual Execution

You can also run the script manually:

```bash
# Set required environment variables
export CLUSTER_NAME="your-cluster-name"
export AWS_REGION="us-east-1"

# Run the script
cd scripts
chmod +x 02-setup-load-balancer.sh
./02-setup-load-balancer.sh
```

## Testing

An optional test script `03-test-load-balancer.sh` is provided to verify the installation:

- Deploys a test nginx application
- Creates an ALB ingress
- Verifies ALB provisioning
- Tests connectivity
- Cleans up test resources

## Verification

After installation, verify the controller is working:

```bash
# Check controller pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Verify service account
kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o yaml
```

## Using ALB Ingress

Once installed, you can create ALB ingresses like this:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
```

## Troubleshooting

### Common Issues

1. **Service Account Already Exists**
   - Script handles this automatically
   - Reuses existing service account if properly configured

2. **IAM Role Conflicts**
   - Script checks for existing roles
   - Uses existing role if found with correct policies

3. **Controller Not Starting**
   - Check IAM permissions
   - Verify OIDC provider configuration
   - Review controller logs

### Debug Commands

```bash
# Check cluster OIDC issuer
aws eks describe-cluster --name CLUSTER_NAME --query "cluster.identity.oidc.issuer"

# Check IAM role trust policy
aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole

# Check service account annotations
kubectl describe serviceaccount aws-load-balancer-controller -n kube-system
```

## References

- [Official AWS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html)
- [AWS Load Balancer Controller GitHub](https://github.com/kubernetes-sigs/aws-load-balancer-controller)
- [Helm Chart Documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

## Next Steps

After the load balancer controller is installed:

1. ✅ Controller is ready to provision ALBs
2. ✅ LiveKit can be deployed with ingress resources
3. ✅ External access to LiveKit services is enabled
4. ✅ Production-ready load balancing is configured