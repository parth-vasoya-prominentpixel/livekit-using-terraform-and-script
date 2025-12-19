# GitHub Environments Configuration

This document explains how to set up GitHub environments with manual approval protection rules for the LiveKit pipeline.

## Required Environments

You need to create the following environments in your GitHub repository:

### Development Environment
- `livekit-poc-dev-prerequisites`
- `livekit-poc-dev-terraform-plan`
- `livekit-poc-dev-terraform-apply`
- `livekit-poc-dev-setup-load-balancer`
- `livekit-poc-dev-deploy-livekit`
- `livekit-poc-dev-destroy`

### UAT Environment (Optional)
- `livekit-poc-uat-prerequisites`
- `livekit-poc-uat-terraform-plan`
- `livekit-poc-uat-terraform-apply`
- `livekit-poc-uat-setup-load-balancer`
- `livekit-poc-uat-deploy-livekit`
- `livekit-poc-uat-destroy`

### Production Environment (Optional)
- `livekit-poc-prod-prerequisites`
- `livekit-poc-prod-terraform-plan`
- `livekit-poc-prod-terraform-apply`
- `livekit-poc-prod-setup-load-balancer`
- `livekit-poc-prod-deploy-livekit`
- `livekit-poc-prod-destroy`

## How to Create Environments

1. Go to your GitHub repository
2. Click on **Settings** tab
3. In the left sidebar, click **Environments**
4. Click **New environment**
5. Enter the environment name (e.g., `livekit-poc-dev-prerequisites`)
6. Click **Configure environment**

## Environment Protection Rules

For each environment, configure the following protection rules:

### Required Reviewers
- **Enable**: ✅ Required reviewers
- **Add**: Your username or team members who should approve deployments
- **Number of reviewers**: 1 (minimum)

### Wait Timer (Optional)
- **Enable**: ❌ Wait timer (not needed for manual approval)

### Deployment Branches
- **Selected branches**: `main` (or your default branch)
- This ensures only deployments from the main branch are allowed

## Environment Secrets

Each environment needs the following secrets:

### Required Secrets
- `AWS_OIDC_ROLE_ARN`: The ARN of your AWS OIDC role for GitHub Actions
- `DEPLOYMENT_ROLE_ARN`: The ARN of your deployment role (same as in inputs.tfvars)

### Example Values
```
AWS_OIDC_ROLE_ARN=arn:aws:iam::918595516608:role/github-actions-oidc-role
DEPLOYMENT_ROLE_ARN=arn:aws:iam::918595516608:role/lp-iam-resource-creation-role
```

## Manual Approval Workflow

With these environments configured:

1. **Trigger**: Run the workflow manually from GitHub Actions
2. **Step 1**: Prerequisites step waits for manual approval
3. **Approve**: Review and approve the prerequisites step
4. **Step 2**: Terraform Plan step waits for manual approval
5. **Approve**: Review the plan output and approve
6. **Step 3**: Terraform Apply step waits for manual approval
7. **Approve**: Review and approve infrastructure creation
8. **Step 4**: Load Balancer setup waits for manual approval
9. **Approve**: Review and approve load balancer installation
10. **Step 5**: LiveKit deployment waits for manual approval
11. **Approve**: Review and approve LiveKit deployment

## Benefits of This Approach

- **Full Control**: Every step requires explicit approval
- **Review Opportunity**: You can review logs and outputs before proceeding
- **Safety**: Prevents accidental deployments
- **Audit Trail**: GitHub tracks all approvals and who approved them
- **Rollback**: You can stop the pipeline at any step if issues are detected

## Quick Setup Commands

You can use the GitHub CLI to create environments quickly:

```bash
# Install GitHub CLI first: https://cli.github.com/

# Create dev environments
gh api repos/:owner/:repo/environments/livekit-poc-dev-prerequisites --method PUT
gh api repos/:owner/:repo/environments/livekit-poc-dev-terraform-plan --method PUT
gh api repos/:owner/:repo/environments/livekit-poc-dev-terraform-apply --method PUT
gh api repos/:owner/:repo/environments/livekit-poc-dev-setup-load-balancer --method PUT
gh api repos/:owner/:repo/environments/livekit-poc-dev-deploy-livekit --method PUT
gh api repos/:owner/:repo/environments/livekit-poc-dev-destroy --method PUT
```

Replace `:owner` and `:repo` with your actual GitHub username/organization and repository name.