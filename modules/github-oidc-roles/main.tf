# ======================================================================================
# IAM infrastructure for GitHub Actions CI/CD: a deploy role (full permissions) and a
# plan role (read-only), both assumable via OIDC, no long-lived access keys.
# ======================================================================================

data "aws_caller_identity" "read_current_account" {}

# ======================================================================================
# OIDC provider: the trust relationship between AWS and GitHub that lets GitHub Actions
# authenticate without access keys.
# ======================================================================================
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ======================================================================================
# Trust policy for the terraform_deploy role
# ======================================================================================
data "aws_iam_policy_document" "github_actions_trust_policy" {
  # Management account admins with MFA can assume this role (break-glass).
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

  # GitHub Actions assumes this role via OIDC.
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:environment:production-approval",
        "repo:${var.github_org}/${var.github_repo}:environment:automated",
        "repo:${var.github_org}/${var.github_repo}:environment:teardown-approval",
        "repo:${var.github_org}/${var.github_repo}:environment:management-approval"
      ]
    }
  }
}

# ======================================================================================
# Deploy role permissions
# ======================================================================================
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

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

      # OIDC and policy management
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

  # SSM Parameter Store access, both management and current account.
  statement {
    sid    = "SSMParameterStore"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      # Every aws_ssm_parameter in this repo passes tags = var.tags, which needs
      # this as a separate action from PutParameter: AWS tags a new parameter via
      # its own API call. RemoveTagsFromResource covers the reverse (a tag
      # dropped from var.tags later).
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      # Reads back a parameter's current tags on every plan/apply to diff against
      # var.tags. Unlike ssm:DescribeParameters, this supports resource-level
      # scoping, so it belongs here rather than in SSMDescribeParameters below.
      "ssm:ListTagsForResource"
    ]
    resources = [
      # Management account paths
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/transit-gateway/*",
      # Current account paths
      "arn:aws:ssm:eu-west-2:${data.aws_caller_identity.read_current_account.account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${data.aws_caller_identity.read_current_account.account_id}:parameter/transit-gateway/*"
    ]
  }

  # ssm:DescribeParameters doesn't support resource-level permissions at all: AWS
  # always evaluates it against the account-wide "*" resource, never a specific
  # parameter ARN, since it's a filter/search API over the whole parameter store.
  # Scoping it in SSMParameterStore above looks correct but silently grants
  # nothing, so it needs its own statement at resources = ["*"].
  statement {
    sid       = "SSMDescribeParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid       = "AssumeManagementSSMReadOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"]
  }

  dynamic "statement" {
    for_each = length(var.extra_assumable_role_arns) > 0 ? [1] : []
    content {
      sid       = "AssumeExtraRoles"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.extra_assumable_role_arns
    }
  }

  # S3 state file access, scoped to this account's own prefix only, not the whole
  # bucket. Every account's TerraformDeploy role has this same statement, each
  # scoped to its own prefix, so no account's pipeline can touch another
  # account's state file. state_key_prefix must match this account's own
  # backend "s3" { key = "..." }.
  statement {
    sid    = "StateFileAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # the .tflock file use_lockfile writes/deletes
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}/${var.state_key_prefix}/*"
    ]
  }

  # ListBucket is a bucket-level action (its resource is the bucket ARN, never an
  # object path), so it can't be scoped by a prefix on the resource ARN like the
  # statement above. s3:prefix is the only way to restrict which prefix a
  # ListBucket call can see.
  statement {
    sid       = "ListOwnPrefixOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.state_key_prefix}/*"]
    }
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
      "ram:ListResourceSharePermissions",
      "ram:EnableSharingWithAwsOrganization",
      # Tag-on-create: RAM evaluates ram:TagResource against resource-share/*
      # before the share ARN exists, so this statement must stay at Resource "*".
      "ram:TagResource",
      "ram:UntagResource",
      "ram:ListTagsForResource"
    ]
    resources = ["*"]
  }

}

resource "aws_iam_role" "terraform_deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.github_actions_trust_policy.json
  max_session_duration = 3600

  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy" "terraform_deploy_policy" {
  name   = "TerraformDeployPermissions"
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

# ======================================================================================
# Trust policy for the terraform_plan role
# ======================================================================================
data "aws_iam_policy_document" "github_oidc_trust_plan" {
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
      values = [
        "repo:${var.github_org}/${var.github_repo}:pull_request",
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

# Read-only role for the terraform plan workflow: can read resources, not modify them
resource "aws_iam_role" "terraform_plan" {
  name                 = "TerraformPlan"
  assume_role_policy   = data.aws_iam_policy_document.github_oidc_trust_plan.json
  max_session_duration = 3600

  tags = {
    ManagedBy   = "github-actions"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Lets terraform_plan temporarily assume SSMReadOnly in the management account,
# to read SSM parameters from there during planning.
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

resource "aws_iam_role_policy" "terraform_plan_assume_extra_roles" {
  count = length(var.extra_assumable_role_arns) > 0 ? 1 : 0

  name = "AssumeExtraRoles"
  role = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.extra_assumable_role_arns
    }]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# S3 state file access for terraform_plan, scoped to this account's own prefix
# only, same as TerraformDeploy's StateFileAccess statement above.
#
# The ReadOnlyAccess managed policy attached below already grants
# s3:GetObject/s3:ListBucket on every bucket in the account, unscoped, so this
# policy's read actions are redundant with that. What actually matters here is
# PutObject/DeleteObject (state locking), which ReadOnlyAccess does not grant,
# and which a PR-triggered plan should never have outside its own prefix.
resource "aws_iam_policy" "terraform_plan_s3_role" {
  name = "TerraformPlanS3Policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateFileAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",    # required for S3 state locking (.tflock file)
          "s3:DeleteObject", # required to clean up lock files
        ]
        Resource = ["arn:aws:s3:::${var.state_bucket_name}/${var.state_key_prefix}/*"]
      },
      {
        # Bucket-level action, must target the bucket ARN not an object path
        # (see ListOwnPrefixOnly above). Listed mainly for parity with Deploy;
        # ReadOnlyAccess already covers this in practice.
        Sid      = "ListOwnPrefixOnly"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.state_bucket_name}"]
        Condition = {
          StringLike = {
            "s3:prefix" = ["${var.state_key_prefix}/*"]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_s3_policy_attachment" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = aws_iam_policy.terraform_plan_s3_role.arn
}

output "role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}

output "role_name" {
  value = aws_iam_role.terraform_deploy.name
}

output "plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}
