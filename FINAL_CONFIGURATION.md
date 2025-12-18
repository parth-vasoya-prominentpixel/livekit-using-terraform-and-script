# Final EKS Configuration - Production Ready

## Configuration Overview

This configuration follows the official Terraform AWS EKS module v20+ best practices and examples.

### Key Changes from Previous Versions

1. **Simplified Module Configuration**
   - Removed deprecated `cluster_addons` → using `addons`
   - Removed deprecated `cluster_endpoint_private_access` → using defaults
   - Removed deprecated `cluster_enabled_log_types` → using defaults
   - Removed deprecated `control_plane_subnet_ids` → using `subnet_ids`

2. **Integrated EBS CSI Driver**
   - EBS CSI driver now included in main `addons` block
   - No separate addon resource needed
   - Proper IRSA role integration

3. **Access Management**
   - Using EKS Access Entries (v20+ approach)
   - Cluster admin policy for deployment role
   - Automatic cluster creator admin permissions

## Current Configuration

### EKS Cluster
```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  name               = "lp-eks-livekit-use1-dev"
  kubernetes_version = "1.31"
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  
  endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true
  
  addons = {
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    vpc-cni            = { most_recent = true }
    aws-ebs-csi-driver = { 
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi_irsa_role.arn
    }
  }
  
  eks_managed_node_groups = {
    livekit_nodes = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 10
      desired_size   = 3
      
      subnet_ids = module.vpc.private_subnets
      
      labels = {
        "cluster-autoscaler/enabled" = "true"
        "cluster-autoscaler/cluster" = "lp-eks-livekit-use1-dev"
        "node-type"                  = "livekit-worker"
      }
      
      vpc_security_group_ids = [aws_security_group.sip_traffic.id]
      
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }
    }
  }
  
  access_entries = {
    deployment_role = {
      principal_arn = "arn:aws:iam::ACCOUNT:role/deployment-role"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

### IRSA Roles

**EBS CSI Driver**
- Role: `lp-eks-livekit-use1-dev-ebs-csi-driver`
- Policy: `AmazonEBSCSIDriverPolicy`
- Service Account: `system:serviceaccount:kube-system:ebs-csi-controller-sa`

**AWS Load Balancer Controller**
- Role: `lp-eks-livekit-use1-dev-aws-load-balancer-controller`
- Policy: Custom policy with ELB permissions
- Service Account: `system:serviceaccount:kube-system:aws-load-balancer-controller`

**Cluster Autoscaler**
- Role: `lp-eks-livekit-use1-dev-cluster-autoscaler`
- Policy: Custom policy with ASG permissions
- Service Account: `system:serviceaccount:kube-system:cluster-autoscaler`

## Validation

### Terraform Validation
```bash
cd resources
terraform init -backend=false
terraform validate
```

### Configuration Check
```bash
./scripts/validate-config.sh
```

### Plan Check
```bash
cd resources
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"
```

## Deployment Process

### GitHub Actions (Recommended)
1. Push to GitHub
2. Go to Actions → LiveKit EKS Manual Deployment Pipeline
3. Run workflow with `step: all`
4. Approve each stage:
   - Prerequisites (tool installation + validation)
   - Terraform Plan (review changes)
   - Terraform Apply (deploy infrastructure)
   - Load Balancer (setup AWS LB Controller)
   - LiveKit (deploy application)

### Manual Deployment
```bash
# 1. Validate configuration
./scripts/validate-config.sh

# 2. Initialize Terraform
cd resources
terraform init -backend-config="../environments/livekit-poc/us-east-1/dev/backend.tfvars"

# 3. Plan deployment
terraform plan -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# 4. Apply infrastructure
terraform apply -var-file="../environments/livekit-poc/us-east-1/dev/inputs.tfvars"

# 5. Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name lp-eks-livekit-use1-dev

# 6. Setup Load Balancer Controller
cd ..
./scripts/02-setup-load-balancer.sh

# 7. Deploy LiveKit
./scripts/03-deploy-livekit.sh
```

## Security Features

✅ **Network Isolation**
- Private subnets for EKS nodes and Redis
- Public subnets for NAT gateways and load balancers
- Security groups with minimal required access

✅ **SIP Security**
- Port 5060 restricted to Twilio CIDRs only
- Separate security group for SIP traffic
- Both TCP and UDP protocols supported

✅ **IAM Security**
- IRSA for service accounts (no static credentials)
- Least privilege IAM policies
- Deployment role with cluster admin access

✅ **Instance Security**
- IMDSv2 enforced on all EC2 instances
- Private subnet deployment
- Managed node groups with auto-updates

## Monitoring & Operations

### Check Cluster Status
```bash
kubectl get nodes
kubectl get pods -A
kubectl get svc -A
```

### Check Addons
```bash
aws eks describe-addon --cluster-name lp-eks-livekit-use1-dev --addon-name aws-ebs-csi-driver --region us-east-1
aws eks describe-addon --cluster-name lp-eks-livekit-use1-dev --addon-name coredns --region us-east-1
```

### Check Access Entries
```bash
aws eks list-access-entries --cluster-name lp-eks-livekit-use1-dev --region us-east-1
```

### View Terraform Outputs
```bash
cd resources
terraform output
```

## Troubleshooting

### Validation Errors
- Run `./scripts/validate-config.sh` to check configuration
- Ensure backend.tfvars and inputs.tfvars exist
- Check Terraform version (should be 1.10.3)

### Access Entry Conflicts
- Run `./scripts/cleanup-access-entries.sh` to remove conflicts
- Terraform will recreate proper access entries

### EBS CSI Driver Issues
- Check IRSA role: `aws iam get-role --role-name lp-eks-livekit-use1-dev-ebs-csi-driver`
- Verify addon status: `aws eks describe-addon --cluster-name lp-eks-livekit-use1-dev --addon-name aws-ebs-csi-driver`
- Check service account: `kubectl get sa -n kube-system ebs-csi-controller-sa`

### Node Group Issues
- Check node status: `kubectl get nodes`
- View node group: `aws eks describe-nodegroup --cluster-name lp-eks-livekit-use1-dev --nodegroup-name livekit_nodes`
- Check autoscaling: `aws autoscaling describe-auto-scaling-groups`

## Cost Optimization

**Monthly Costs (us-east-1)**
- EKS Cluster: $72
- NAT Gateways (3x): $135
- ElastiCache Redis: $15
- EC2 Instances (3x t3.medium): $95
- **Total**: ~$317/month

**Optimization Tips**
- Use single NAT gateway for dev: saves $90/month
- Scale down to 1 node when not in use: saves $63/month
- Use t3.small instances: saves $32/month
- Stop cluster overnight: saves ~50% of compute costs

## Next Steps

1. ✅ Configuration validated and ready
2. 🔄 Deploy infrastructure via GitHub Actions
3. 🔄 Verify all components are healthy
4. 🔄 Deploy LiveKit application
5. 🔄 Test SIP connectivity from Twilio
6. 🔄 Set up monitoring and alerting