# LiveKit EKS Deployment - Ready to Use

This deployment is now **production-ready** with proper dynamic configuration and LoadBalancer handling.

## 🚀 Quick Start

### 1. Prerequisites
- AWS CLI configured with proper credentials
- kubectl installed
- Helm installed
- Terraform infrastructure deployed

### 2. Configuration
Edit `livekit.env` to customize your deployment:
```bash
# AWS Configuration
AWS_REGION=us-east-1
CLUSTER_NAME=lp-eks-livekit-use1-dev

# LiveKit Domains
DOMAIN=livekit-eks-tf.digi-telephony.com
TURN_DOMAIN=turn.livekit-eks-tf.digi-telephony.com

# API Credentials (change these!)
API_KEY=APIKmrHi78hxpbd
SECRET_KEY=Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB

# Autoscaling (1-20 replicas at 75% CPU)
MIN_REPLICAS=1
MAX_REPLICAS=20
CPU_THRESHOLD=75
```

### 3. Deploy LiveKit
```bash
# Make sure you're in the project root
./scripts/03-deploy-livekit.sh
```

## ✨ Key Features

### 🔧 Dynamic Configuration
- **Redis endpoint** is automatically retrieved from Terraform outputs
- **Cluster information** is dynamically gathered from AWS
- **No hardcoded values** - everything is configurable or auto-detected

### ⏳ Smart LoadBalancer Handling
- **10-minute timeout** for LoadBalancer provisioning
- **Progress tracking** with percentage completion
- **Health checks** when LoadBalancer is ready
- **Graceful handling** of provisioning delays

### 🚀 Intelligent Deployment
- **Health checks** existing deployments
- **Automatic cleanup** of unhealthy deployments
- **Upgrade vs install** detection
- **3-attempt retry** logic with proper error handling

### 📊 Comprehensive Status
- **Real-time monitoring** of pod status
- **Service verification** and endpoint detection
- **Complete connection details** with WebSocket URLs
- **DNS configuration** instructions
- **Monitoring commands** for troubleshooting

## 📋 What the Script Does

1. **Loads Configuration** from `livekit.env`
2. **Verifies AWS credentials** and cluster connectivity
3. **Retrieves Redis endpoint** dynamically from Terraform outputs
4. **Checks Load Balancer Controller** status
5. **Manages namespace** and existing deployments
6. **Sets up Helm repository** and verifies chart availability
7. **Gathers cluster information** for LoadBalancer configuration
8. **Generates Helm values** with all dynamic configuration
9. **Deploys LiveKit** with retry logic and proper error handling
10. **Waits for pods** to be ready with timeout
11. **Provisions LoadBalancer** with progress tracking
12. **Tests health** and provides complete status
13. **Shows connection details** and monitoring commands

## 🔍 Troubleshooting

### Redis Endpoint Issues
```bash
# Check Terraform outputs
cd resources
terraform output redis_cluster_endpoint

# If empty, check if Redis is deployed
terraform output | grep redis
```

### LoadBalancer Issues
```bash
# Check LoadBalancer Controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check service status
kubectl get svc -n livekit

# Check events
kubectl get events -n livekit
```

### Pod Issues
```bash
# Check pod status
kubectl get pods -n livekit

# Check logs
kubectl logs -n livekit -l app.kubernetes.io/name=livekit-server

# Check HPA
kubectl get hpa -n livekit
```

## 📁 File Structure

```
├── livekit.env                    # Common configuration (edit this)
├── scripts/
│   ├── 02-setup-load-balancer.sh # Setup AWS Load Balancer Controller
│   ├── 03-deploy-livekit.sh      # Main deployment script
│   └── get-redis-endpoint.sh     # Helper to get Redis endpoint
└── resources/                     # Terraform infrastructure
    ├── *.tf                       # Terraform configuration
    └── terraform.tfstate          # Terraform state (contains Redis endpoint)
```

## 🎯 Connection Details

After successful deployment, you'll get:

### WebSocket URLs
- **Direct LoadBalancer**: `ws://[ALB-ENDPOINT]`
- **Domain** (after DNS): `ws://livekit-eks-tf.digi-telephony.com`

### API Credentials
- **API Key**: `APIKmrHi78hxpbd`
- **Secret**: `Y3vpZUiNQyC8DdQevWeIdzfMgmjs5hUycqJA22atniuB`

### TURN Server
- **TURN URL**: `turn:turn.livekit-eks-tf.digi-telephony.com:3478`

## 🔄 Autoscaling

- **Min Replicas**: 1
- **Max Replicas**: 20
- **CPU Threshold**: 75%
- **Resources**: 500m-2000m CPU, 1Gi-2Gi Memory

## 💡 Production Notes

1. **Change API credentials** in `livekit.env` for production
2. **Configure DNS** to point domains to LoadBalancer endpoint
3. **Monitor resources** using provided kubectl commands
4. **Scale as needed** by adjusting MIN_REPLICAS and MAX_REPLICAS
5. **Redis endpoint** is automatically retrieved - no manual configuration needed

## ✅ Ready for Production

This deployment is now **complete and production-ready** with:
- ✅ Dynamic Redis endpoint retrieval
- ✅ Proper LoadBalancer provisioning
- ✅ Comprehensive error handling
- ✅ Smart deployment logic
- ✅ Complete monitoring and status
- ✅ Clean file organization
- ✅ No hardcoded values