# GitHub Actions OIDC Setup for AWS

This document explains how to set up OpenID Connect (OIDC) authentication between GitHub Actions and AWS for secure, keyless authentication.

## 🔐 Why OIDC?

OIDC provides several advantages over traditional AWS access keys:
- **No long-lived credentials** stored in GitHub secrets
- **Fine-grained permissions** with temporary credentials
- **Audit trail** of which workflows accessed AWS resources
- **Automatic credential rotation**

## 🏗️ Setup Steps

### 1. Create OIDC Identity Provider in AWS

```bash
# Create the OIDC identity provider
aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
    --tags Key=Name,Value=GitHubActions-OIDC
```

### 2. Create IAM Role for GitHub Actions

Create a file `github-actions-trust-policy.json`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:*"
                }
            }
        }
    ]
}
```

Create the IAM role:

```bash
# Replace YOUR_ACCOUNT_ID, YOUR_GITHUB_USERNAME, and YOUR_REPO_NAME
aws iam create-role \
    --role-name GitHubActions-LiveKit-Role \
    --assume-role-policy-document file://github-actions-trust-policy.json \
    --description "Role for GitHub Actions to deploy LiveKit on EKS"
```

### 3. Create IAM Policy for LiveKit Deployment

Create a file `livekit-deployment-policy.json`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:*",
                "eks:*",
                "elasticache:*",
                "iam:*",
                "kms:*",
                "logs:*",
                "sts:GetCallerIdentity",
                "sts:AssumeRole"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::your-terraform-state-bucket",
                "arn:aws:s3:::your-terraform-state-bucket/*"
            ]
        }
    ]
}
```

Create and attach the policy:

```bash
# Create the policy
aws iam create-policy \
    --policy-name GitHubActions-LiveKit-Policy \
    --policy-document file://livekit-deployment-policy.json \
    --description "Policy for GitHub Actions to deploy LiveKit infrastructure"

# Attach the policy to the role
aws iam attach-role-policy \
    --role-name GitHubActions-LiveKit-Role \
    --policy-arn arn:aws:iam::YOUR_ACCOUNT_ID:policy/GitHubActions-LiveKit-Policy
```

### 4. Set GitHub Repository Secrets

Add the following secret to your GitHub repository:

1. Go to your repository → Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Add:
   - **Name**: `AWS_OIDC_ROLE_ARN`
   - **Value**: `arn:aws:iam::YOUR_ACCOUNT_ID:role/GitHubActions-LiveKit-Role`

### 5. Create Environment Protection Rules

1. Go to your repository → Settings → Environments
2. Create environments:
   - `dev-approval`
   - `uat-approval` 
   - `prod-approval`
3. For each environment, configure:
   - **Required reviewers**: Add team members who can approve deployments
   - **Wait timer**: Optional delay before deployment
   - **Deployment branches**: Restrict which branches can deploy

## 🔧 Terraform Backend Configuration (Optional)

For production use, configure Terraform to use S3 backend:

Create `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "livekit-eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
```

Create S3 bucket and DynamoDB table:

```bash
# Create S3 bucket for Terraform state
aws s3 mb s3://your-terraform-state-bucket --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
    --bucket your-terraform-state-bucket \
    --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
    --table-name terraform-state-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region us-east-1
```

## 🔍 Verification

Test the OIDC setup:

```bash
# Test assuming the role (replace with your values)
aws sts assume-role-with-web-identity \
    --role-arn arn:aws:iam::YOUR_ACCOUNT_ID:role/GitHubActions-LiveKit-Role \
    --role-session-name test-session \
    --web-identity-token "$(curl -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')"
```

## 🛡️ Security Best Practices

1. **Least Privilege**: Only grant necessary permissions
2. **Condition Constraints**: Use specific repository and branch conditions
3. **Regular Auditing**: Review CloudTrail logs for OIDC usage
4. **Environment Protection**: Use GitHub environments for production deployments
5. **Secrets Rotation**: Regularly review and rotate any remaining secrets

## 🔗 Useful Links

- [GitHub OIDC Documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [AWS IAM OIDC Documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [Terraform AWS Provider OIDC](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#assuming-an-iam-role)

## 🆘 Troubleshooting

### Common Issues:

1. **"No OpenIDConnect provider found"**
   - Verify OIDC provider is created in correct AWS account
   - Check thumbprint is correct

2. **"AssumeRoleWithWebIdentity is not authorized"**
   - Verify trust policy conditions match your repository
   - Check repository name and branch patterns

3. **"Access Denied" during deployment**
   - Review IAM policy permissions
   - Check resource-specific permissions

### Debug Commands:

```bash
# List OIDC providers
aws iam list-open-id-connect-providers

# Get role details
aws iam get-role --role-name GitHubActions-LiveKit-Role

# List attached policies
aws iam list-attached-role-policies --role-name GitHubActions-LiveKit-Role
```