# LiveKit EKS Deployment Workflow

This guide provides the complete workflow for deploying LiveKit on Amazon EKS with proper load balancer configuration.

## Prerequisites

Before starting, ensure you have:

1. **AWS CLI configured** with appropriate permissions
2. **kubectl** installed and configured
3. **Helm** installed (v3.x)
4. **eksctl** installed
5. **Terraform** applied (EKS cluster and Redis created)

Run the prerequisites check:
```bash
./scripts/00-prerequisites.sh
```

## Deployment Steps

### Step 1: Apply Terraform Infrastructure

First, apply your Terraform configuration to create the EKS cluster and Redis:

```bash
cd resources
terraform init
terraform plan
terraform apply
```

Wait for the cluster to be in `ACTIVE` state (15-20 minutes).

### Step 2: Setup AWS Load Balancer Controller

The load balancer controller is required for ALB/NLB provisioning in EKS.

```bash
export CLUSTER_NAME="lp-eks-livekit-use1-dev"  # Your cluster name
export AWS_REGION="us-east-1"                  # Your AWS region

./scripts/02-setup-load-balancer.sh
```

**What this script does:**
- ✅ Follows official AWS documentation exactly
- ✅ Creates IAM policy for load balancer controller
- ✅ Sets up service account with proper IAM role
- ✅ Installs AWS Load Balancer Controller via Helm
- ✅ Handles existing installations and conflicts
- ✅ Verifies installation and pod health
- ✅ Includes comprehensive error handling

**Expected output:**
- IAM policy created or verified
- Service account with IAM role created
- Load balancer controller pods running
- Ready for application load balancer provisioning

### Step 3: Deploy LiveKit

Deploy LiveKit with proper AWS integration:

```bash
export CLUSTER_NAME="lp-eks-livekit-use1-dev"                    # Your cluster name
export REDIS_ENDPOINT="your-redis-cluster.cache.amazonaws.com"   # From Terraform output
export AWS_REGION="us-east-1"                                    # Your AWS region

./scripts/03-deploy-livekit.sh
```

**What this script does:**
- ✅ Follows LiveKit official documentation
- ✅ Verifies load balancer controller is ready
- ✅ Creates optimized LiveKit configuration
- ✅ Configures ALB for HTTP/WebSocket traffic
- ✅ Configures NLB for RTC UDP traffic
- ✅ Sets up proper health checks
- ✅ Handles upgrades and existing deployments
- ✅ Includes production-ready settings

**Expected output:**
- LiveKit pods running in `livekit` namespace
- ALB created for HTTP/WebSocket traffic
- NLB created for RTC traffic
- Health endpoints responding

## Verification

### Check Load Balancer Controller
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### Check LiveKit Deployment
```bash
kubectl get all -n livekit
```

### Check LoadBalancer Endpoints
```bash
# ALB for HTTP/WebSocket
kubectl get ingress -n livekit

# NLB for RTC traffic
kubectl get svc -n livekit
```

### Test Health Endpoint
```bash
# Get ALB endpoint
ALB_ENDPOINT=$(kubectl get ingress -n livekit -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

# Test health
curl https://$ALB_ENDPOINT/health
```

## Configuration Details

### Load Balancer Controller Features
- **IAM Integration**: Uses IAM roles for service accounts (IRSA)
- **VPC Integration**: Automatically detects VPC and subnets
- **Security Groups**: Creates appropriate security groups
- **Health Checks**: Configures proper health check endpoints
- **SSL/TLS**: Supports ACM certificate integration

### LiveKit Configuration Features
- **High Availability**: 2 replicas with pod anti-affinity
- **Resource Limits**: Proper CPU/memory limits
- **Redis Integration**: External Redis for scalability
- **Monitoring**: Metrics and health endpoints enabled
- **Security**: Non-root containers with security context

### LoadBalancer Types
- **ALB (Application Load Balancer)**: For HTTP/WebSocket traffic
  - Layer 7 load balancing
  - SSL termination
  - Path-based routing
- **NLB (Network Load Balancer)**: For RTC UDP traffic
  - Layer 4 load balancing
  - High performance
  - Static IP addresses

## Troubleshooting

### Load Balancer Controller Issues
```bash
# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check IAM permissions
aws sts get-caller-identity
kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o yaml
```

### LiveKit Issues
```bash
# Check pod logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit

# Check service status
kubectl describe svc -n livekit

# Check ingress status
kubectl describe ingress -n livekit
```

### Common Issues and Solutions

1. **Load Balancer Controller Not Installing**
   - Verify OIDC provider is configured
   - Check IAM permissions
   - Ensure cluster is in ACTIVE state

2. **LoadBalancer Stuck in Pending**
   - Check subnet tags for load balancer discovery
   - Verify security group rules
   - Check AWS service quotas

3. **Health Checks Failing**
   - Verify health endpoint path
   - Check security group ingress rules
   - Ensure pods are running and ready

## DNS Configuration

After deployment, configure DNS to point your domain to the ALB:

```bash
# Get ALB endpoint
ALB_ENDPOINT=$(kubectl get ingress -n livekit -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

echo "Configure DNS:"
echo "livekit.digi-telephony.com CNAME $ALB_ENDPOINT"
```

## Production Considerations

1. **Security**
   - Use proper API keys and secrets
   - Configure network policies
   - Enable pod security standards

2. **Monitoring**
   - Set up Prometheus monitoring
   - Configure log aggregation
   - Set up alerting

3. **Scaling**
   - Configure horizontal pod autoscaler
   - Set up cluster autoscaler
   - Monitor resource usage

4. **Backup**
   - Backup Redis data
   - Document configuration
   - Test disaster recovery

## Next Steps

1. Configure DNS for your domain
2. Test LiveKit client connections
3. Set up monitoring and alerting
4. Configure backup and disaster recovery
5. Implement CI/CD for updates

## Support

- **AWS Load Balancer Controller**: [Official Documentation](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html)
- **LiveKit**: [Official Documentation](https://docs.livekit.io/deploy/kubernetes/)
- **EKS**: [Official Documentation](https://docs.aws.amazon.com/eks/)