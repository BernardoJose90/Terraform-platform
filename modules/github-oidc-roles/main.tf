# ======================================================================================
# Terraform code which creates IAM infrastructure for GitHub Actions CI/CD with two separate roles
# ======================================================================================

# Get current account ID for dynamic permissions
data "aws_caller_identity" "read_current_account" {}

# ======================================================================================
# Creates OIDC PROVIDER IN AWS which is a trust relationship between AWS & GitHub 
# Allowing GitHub Actions to authenticate with AWS without using access keys
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

# =====================================================================================================================
# This creates trust policy for GitHub Actions basically allowing GitHub Actions to assume the terraform_deploy role
# =====================================================================================================================
data "aws_iam_policy_document" "github_actions_trust_policy" {
  # Allows management account admins with MFA to assume this role (emergency access)
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

  # Allows GitHub Actions to assume this role via OIDC
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
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

# ======================================================================================
# Creates Permissions with all required IAM actions
# ======================================================================================
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  #IAM permissions
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

  # SSM Parameter Store Access to BOTH management AND current account
  statement {
    sid    = "SSMParameterStore"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      # aws_ssm_parameter resources created with tags (every one of them in this
      # repo — they all pass tags = var.tags) need this as a SEPARATE action from
      # ssm:PutParameter. AWS tags a new SSM parameter via its own API call under
      # the hood, so PutParameter alone creates the parameter but then fails to
      # tag it. RemoveTagsFromResource is here too, for the same reason on the
      # update/delete side (e.g. a tag being removed from var.tags later).
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource"
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

  # ssm:DescribeParameters doesn't support resource-level permissions at all —
  # AWS always evaluates it against the account-wide "arn:...:ssm:region:account:*"
  # resource, never a specific parameter ARN, because it's a filter/search API
  # over the whole parameter store rather than a per-parameter read. Putting it
  # in SSMParameterStore above (scoped to transit-gateway/* etc.) looks correct
  # but never actually grants it — AWS silently ignores that scoping for this
  # one action and denies, since no statement covers the "*" resource it's
  # really evaluated against. The aws_ssm_parameter resource calls this during
  # its tag-reconciliation on every apply, so it has to be its own statement.
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

  # S3 state file access, scoped to this account's own prefix only — not
  # the whole bucket. Every other account's TerraformDeploy role has this
  # same statement, each scoped to its own prefix, so no account's deploy
  # pipeline can touch another account's state file (accidentally or via
  # a compromised/misconfigured workflow). state_key_prefix must match the
  # backend "s3" { key = "..." } this account's own main.tf uses.
  statement {
    sid    = "StateFileAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # includes the .tflock file use_lockfile writes/deletes
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}/${var.state_key_prefix}/*"
    ]
  }

  # ListBucket is a bucket-level action — its resource is the bucket ARN
  # itself, never an object path, so it can't be scoped by appending a
  # prefix to the resource ARN the way the statement above is. The only
  # way to restrict *which* prefix a ListBucket call can see is the
  # s3:prefix condition key.
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

  # RAM Permissions
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
      # Tag-on-create. RAM evaluates ram:TagResource against resource-share/* BEFORE
      # the share ARN exists, so this statement must stay at resources = ["*"].
      "ram:TagResource",
      "ram:UntagResource",
      "ram:ListTagsForResource"
    ]
    resources = ["*"]
  }

}

# ==============================================================================
# RESOURCE: TERRAFORM DEPLOY ROLE THIS IS THE ACTUAL RESOURCE THAT GETS CREATED
# ==============================================================================
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

# ======================================================================================
# ATTACH THE PERMISSIONS POLICY TO THE terraform_deploy ROLE 
# ======================================================================================
resource "aws_iam_role_policy" "terraform_deploy_policy" {
  name   = "TerraformDeployPermissions"
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

# =======================================================================================
# creates a trust policy that allows GitHub Actions to assume the Terraform Plan role
# =======================================================================================
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

# ======================================================================================
# Creates a read-only role for Github Action to run terraform plan workflow. 
# This role has limited permissions and can only read resources, not modify them.
# ======================================================================================
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

# ======================================================================================
# creates an inline IAM policy that allows the Terraform Plan role to assume another role in the management account
# What it does: Allows the Terraform Plan role role to temporarily assume the SSMReadOnly role in the management account
# Why needed: To read SSM parameters from the management account during planning
# ======================================================================================
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

# ======================================================================================
# attaches custom policy to the terraform_plan only role
# ======================================================================================
resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ======================================================================================
# Creates custom S3 policy for state file access - scoped to this account's own
# prefix only, same as TerraformDeploy's StateFileAccess statement above.
#
# NOTE: the ReadOnlyAccess managed policy attached below (terraform_plan_readonly)
# already grants s3:GetObject/s3:ListBucket on every bucket in the account,
# unscoped — so this policy's read actions are redundant with that. What actually
# matters here is PutObject/DeleteObject (state locking), which ReadOnlyAccess does
# NOT grant, and which is the one thing a PR-triggered plan should never have
# outside its own prefix.
# ======================================================================================
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
          "s3:PutObject",    # ← REQUIRED for S3 state locking (creates .tflock file)
          "s3:DeleteObject", # ← REQUIRED to clean up lock files
        ]
        Resource = ["arn:aws:s3:::${var.state_bucket_name}/${var.state_key_prefix}/*"]
      },
      {
        # Bucket-level action — must target the bucket ARN, not an object path
        # (see the ListOwnPrefixOnly statement above for the same reasoning).
        # Listed here mainly for parity with Deploy; ReadOnlyAccess already
        # covers this in practice.
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

# ======================================================================================
# attaches custom S3 policy to the terraform_plan_s3_role
# ======================================================================================
resource "aws_iam_role_policy_attachment" "terraform_plan_s3_policy_attachment" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = aws_iam_policy.terraform_plan_s3_role.arn
}

# =============================================
# OUTPUTS
# =============================================
output "role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}

output "role_name" {
  value = aws_iam_role.terraform_deploy.name
}

output "plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}
