# IAM Roles Setup for LiveKit EKS Deployment

Since you already have the IAM roles configured, here's how to integrate them with the deployment pipeline.

## 🔐 Required Roles

You need two roles configured:

### 1. GitHub Actions OIDC Role
- **Purpose**: Allows GitHub Actions to authenticate to AWS
- **Permissions**: Minimal - only `sts:AssumeRole` to the deployment role
- **Trust Policy**: Trusts GitHub Actions OIDC provider for your repository

### 2. Deployment Role  
- **Purpose**: Has full permissions to deploy infrastructure
- **Permissions**: Comprehensive AWS permissions for EKS, VPC, ElastiCache, etc.
- **Trust Policy**: Can be assumed by the GitHub Actions OIDC role

## ⚙️ Configuration Steps

### 1. GitHub Repository Secrets

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

```
AWS_OIDC_ROLE_ARN = arn:aws:iam::YOUR_ACCOUNT_ID:role/YOUR_GITHUB_OIDC_ROLE
DEPLOYMENT_ROLE_ARN = arn:aws:iam::YOUR_ACCOUNT_ID:role/YOUR_DEPLOYMENT_ROLE
```

### 2. Update Terraform Variables

Edit `environments/livekit-poc/us-east-1/dev/inputs.tfvars`:

```hcl
# Replace with your actual deployment role ARN
deployment_role_arn = "arn:aws:iam::YOUR_ACCOUNT_ID:role/YOUR_DEPLOYMENT_ROLE"
```

### 3. Verify Role Configuration

The deployment role should have permissions for:
- **EC2**: VPC, subnets, security groups, instances
- **EKS**: Cluster creation, node groups, addons
- **ElastiCache**: Redis cluster creation and management
- **IAM**: Service roles and policies for EKS
- **Auto Scaling**: Node group scaling
- **Elastic Load Balancing**: ALB creation and management
- **Route53**: DNS management (if needed)
- **ACM**: SSL certificate management
- **CloudWatch Logs**: Logging configuration

## 🔄 How It Works

### Authentication Flow
```
GitHub Actions → OIDC Role → Deployment Role → AWS Resources
```

1. **GitHub Actions** authenticates using OIDC token
2. **OIDC Role** is assumed with minimal permissions
3. **Deployment Role** is assumed by OIDC role for actual deployment
4. **AWS Resources** are created using deployment role permissions

### Terraform Provider Configuration
The Terraform AWS provider is configured to assume the deployment role:

```hcl
provider "aws" {
  region = var.region

  # Assume deployment role if provided
  dynamic "assume_role" {
    for_each = var.deployment_role_arn != "" ? [1] : []
    content {
      role_arn     = var.deployment_role_arn
      session_name = "terraform-livekit-deployment"
    }
  }
}
```

## 🧪 Testing the Setup

### 1. Test OIDC Authentication
Run the workflow with `step: prerequisites` to verify GitHub Actions can authenticate.

### 2. Test Role Assumption
Run the workflow with `step: terraform-plan` to verify the deployment role can be assumed.

### 3. Verify Permissions
Check that the deployment role has all necessary permissions by reviewing the Terraform plan output.

## 🛡️ Security Best Practices

### Role Separation Benefits
- **Principle of Least Privilege**: GitHub Actions has minimal permissions
- **Audit Trail**: Clear separation between authentication and deployment
- **Blast Radius Limitation**: OIDC role can't directly access AWS resources
- **Temporary Credentials**: All credentials are short-lived tokens

### Monitoring
- **CloudTrail**: Monitor all role assumptions and API calls
- **IAM Access Analyzer**: Review role permissions regularly
- **GitHub Actions Logs**: Monitor workflow executions

## 🔧 Troubleshooting

### Common Issues

#### 1. "AssumeRoleWithWebIdentity is not authorized"
- Verify OIDC provider is configured correctly
- Check trust policy on OIDC role matches your repository
- Ensure thumbprint is correct for GitHub Actions

#### 2. "User is not authorized to perform: sts:AssumeRole"
- Verify OIDC role has permission to assume deployment role
- Check deployment role trust policy allows OIDC role

#### 3. "Access Denied" during Terraform operations
- Verify deployment role has comprehensive AWS permissions
- Check resource-specific permissions in IAM policy

### Debug Commands

```bash
# Test OIDC role assumption (from GitHub Actions)
aws sts get-caller-identity

# Test deployment role assumption
aws sts assume-role \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/DEPLOYMENT_ROLE \
  --role-session-name test-session

# List role policies
aws iam list-attached-role-policies --role-name YOUR_DEPLOYMENT_ROLE
```

## 📋 Checklist

Before running the deployment:

- [ ] GitHub Actions OIDC role exists and is configured
- [ ] Deployment role exists with comprehensive permissions
- [ ] GitHub repository secrets are configured
- [ ] Terraform variables file is updated with deployment role ARN
- [ ] Trust policies allow proper role assumption chain
- [ ] OIDC provider is configured for GitHub Actions

Once configured, you can run the complete deployment workflow with confidence that the role assumption chain will work securely.