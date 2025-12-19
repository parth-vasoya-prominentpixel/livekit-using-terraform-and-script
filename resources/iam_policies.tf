# IAM Policy for comprehensive EKS access
# This policy provides all necessary permissions for EKS cluster management

data "aws_iam_policy_document" "eks_comprehensive_access" {
  # EKS Cluster permissions
  statement {
    sid    = "EKSClusterAccess"
    effect = "Allow"
    actions = [
      "eks:*"
    ]
    resources = ["*"]
  }

  # EC2 permissions for EKS nodes and networking
  statement {
    sid    = "EC2Access"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
      "ec2:DescribeVpcs",
      "ec2:DescribeSnapshots",
      "ec2:DescribeImages",
      "ec2:DescribeAvailabilityZones",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeTags"
    ]
    resources = ["*"]
  }

  # IAM permissions for service accounts and roles
  statement {
    sid    = "IAMAccess"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:PassRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:ListPolicies",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreateServiceLinkedRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags"
    ]
    resources = ["*"]
  }

  # Auto Scaling permissions for node groups
  statement {
    sid    = "AutoScalingAccess"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup"
    ]
    resources = ["*"]
  }

  # CloudFormation permissions (used by eksctl)
  statement {
    sid    = "CloudFormationAccess"
    effect = "Allow"
    actions = [
      "cloudformation:CreateStack",
      "cloudformation:DeleteStack",
      "cloudformation:DescribeStacks",
      "cloudformation:DescribeStackEvents",
      "cloudformation:DescribeStackResource",
      "cloudformation:DescribeStackResources",
      "cloudformation:GetTemplate",
      "cloudformation:ListStacks",
      "cloudformation:UpdateStack",
      "cloudformation:CreateChangeSet",
      "cloudformation:DeleteChangeSet",
      "cloudformation:DescribeChangeSet",
      "cloudformation:ExecuteChangeSet",
      "cloudformation:ListChangeSets",
      "cloudformation:ValidateTemplate"
    ]
    resources = ["*"]
  }

  # STS permissions for assuming roles
  statement {
    sid    = "STSAccess"
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      "sts:GetCallerIdentity",
      "sts:TagSession"
    ]
    resources = ["*"]
  }

  # KMS permissions for encryption
  statement {
    sid    = "KMSAccess"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ListGrants",
      "kms:RevokeGrant"
    ]
    resources = ["*"]
  }

  # CloudWatch Logs permissions
  statement {
    sid    = "CloudWatchLogsAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:PutRetentionPolicy"
    ]
    resources = ["*"]
  }

  # Elastic Load Balancing permissions
  statement {
    sid    = "ELBAccess"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:*"
    ]
    resources = ["*"]
  }

  # Application Auto Scaling permissions
  statement {
    sid    = "ApplicationAutoScalingAccess"
    effect = "Allow"
    actions = [
      "application-autoscaling:*"
    ]
    resources = ["*"]
  }
}

# Create the comprehensive EKS access policy
resource "aws_iam_policy" "eks_comprehensive_access" {
  name        = "${local.iam_role_prefix}-eks-comprehensive-access-${local.region_prefix}-${var.env}"
  description = "Comprehensive EKS access policy for deployment role"
  policy      = data.aws_iam_policy_document.eks_comprehensive_access.json

  tags = local.tags
}

# Output the policy ARN for reference
output "eks_comprehensive_policy_arn" {
  description = "ARN of the comprehensive EKS access policy"
  value       = aws_iam_policy.eks_comprehensive_access.arn
}