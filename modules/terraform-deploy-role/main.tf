# Trust policy: the management account (human/break-glass access) AND
# GitHub Actions via OIDC (CI) may both assume this role.
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "ManagementAccountBreakGlass"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }

  statement {
    sid     = "GitHubActionsCI"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # ✅ FIXED: Use repo:* to match all GitHub Actions contexts
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:*"
      ]
    }
  }
}

# ✅ Create OIDC provider in the target account
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }
}

# ✅ COMPLETE: Permissions with ALL required IAM actions
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # ✅ COMPLETE IAM permissions
  statement {
    sid    = "ManageInstanceRoles"
    effect = "Allow"
    actions = [
      # Role management
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",

      # Instance profile management
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",

      # OIDC and Policy management
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetPolicy",
      "iam:ListPolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion"
    ]
    resources = ["*"]
  }

  # CloudWatch logging
  statement {
    sid    = "VpnLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup"
    ]
    resources = ["*"]
  }

  # SSM Parameter Store
  statement {
    sid    = "SSMParameterStore"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DescribeParameters",
      "ssm:PutParameter",
      "ssm:DeleteParameter"
    ]
    resources = ["arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*"]
  }

  statement {
    sid       = "AssumeManagementSSMReadOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"]
  }

  # S3 state files
  statement {
    sid    = "StateFileAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*"
    ]
  }

  statement {
    sid    = "RAMPermissions"
    effect = "Allow"
    actions = [
      "ram:CreateResourceShare",
      "ram:DeleteResourceShare",
      "ram:AssociateResourceShare",
      "ram:DisassociateResourceShare",
      "ram:GetResourceShares",
      "ram:GetResourceShareAssociations",
      "ram:EnableSharingWithAwsOrganization"
    ]
    resources = ["*"]
  }

}

resource "aws_iam_role" "terraform_deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }
}

resource "aws_iam_role_policy" "terraform_deploy" {
  name   = "TerraformDeployPermissions"
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

output "role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}

output "role_name" {
  value = aws_iam_role.terraform_deploy.name
}

# --- Separate, read-only role for PR plans ---

data "aws_iam_policy_document" "github_oidc_trust_plan" {
  statement {
    sid     = "GitHubActionsPlan"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

# ✅ S3 permissions for TerraformPlan role
data "aws_iam_policy_document" "plan_s3_access" {
  statement {
    sid    = "StateFileAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*"
    ]
  }
}

# ✅ Custom policy for TerraformPlan role
resource "aws_iam_policy" "terraform_plan_s3" {
  name   = "TerraformPlanS3Policy"
  policy = data.aws_iam_policy_document.plan_s3_access.json
}

resource "aws_iam_role" "terraform_plan" {
  name                 = "TerraformPlan"
  assume_role_policy   = data.aws_iam_policy_document.github_oidc_trust_plan.json
  max_session_duration = 3600
  tags = {
    ManagedBy   = "github-actions"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }
}

resource "aws_iam_role_policy" "terraform_plan_assume_ssm_readonly" {
  name = "AssumeManagementSSMReadOnly"
  role = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ✅ Attach S3 policy to TerraformPlan role
resource "aws_iam_role_policy_attachment" "terraform_plan_s3" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = aws_iam_policy.terraform_plan_s3.arn
}

output "plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}
