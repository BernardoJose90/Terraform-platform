# Trust policy: the management account (human/break-glass access) AND
# GitHub Actions via OIDC (CI) may both assume this role. Two separate
# statements, two separate principals — neither needs to know about the
# other.
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "ManagementAccountBreakGlass"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
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
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

# The OIDC provider — only needs to exist once per account. If this account
# already has one from another stack, remove this block and reference the
# existing provider's ARN in the trust policy above instead (swap
# aws_iam_openid_connect_provider.github.arn for the existing ARN).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Updated permissions with SSM access (no DynamoDB)
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances — all live under ec2:
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # Allow attaching an instance profile/role to the EC2 instance.
  statement {
    sid       = "PassRoleToEc2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Only needed if Terraform also creates the IAM role / instance profile
  statement {
    sid    = "ManageInstanceRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile"
    ]
    resources = ["*"]
  }

  # Optional: VPN tunnel logging to CloudWatch
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
  # SSM Parameter Store permissions
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
  # S3 permissions for state files
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
#
# terraform-plan.yml only needs read access. This is a genuinely NEW role
# (different name, "TerraformPlan" not "TerraformDeploy"), so no collision
# with the role above.
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

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}
