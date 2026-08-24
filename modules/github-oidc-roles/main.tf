# ======================================================================================
# The two IAM roles GitHub Actions uses to run jobs in a workflow: one that can
# make changes (deploy), one that can only look (plan). Both are assumed via
# OIDC — GitHub proves who it is with a short-lived token, so there's no
# long-lived AWS access key sitting in a secret anywhere.
# ======================================================================================

data "aws_caller_identity" "read_current_account" {}

# ======================================================================================
# This is what lets AWS trust a token from GitHub Actions, instead of
# needing a stored access key.
#
# Conditional on var.create_oidc_provider: AWS only allows one OIDC
# provider per unique URL per account, so a caller whose account already
# has one (created elsewhere) sets that variable to false, and the data
# source right below reads the existing one instead of colliding with it.
# Every caller that doesn't set the variable gets exactly the old
# behavior — this module creates and owns the provider, unchanged.
# ======================================================================================
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

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

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  # Whichever path was taken above, this is the one ARN the rest of the
  # module should reference — nothing below here needs to know or care
  # whether the provider was created here or already existed.
  github_oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # The trust policy always accepts these three environments, plus
  # whatever a caller adds via extra_trusted_environments — e.g.
  # terraform-org's platform/ account adding "management-approval" for
  # its own differently-named apply-approval environment. See that
  # variable's description for why this can't just stay a fixed list.
  trusted_environment_subs = concat(
    [
      "repo:${var.github_org}/${var.github_repo}:environment:production-approval",
      "repo:${var.github_org}/${var.github_repo}:environment:automated",
      "repo:${var.github_org}/${var.github_repo}:environment:teardown-approval",
    ],
    [for env in var.extra_trusted_environments : "repo:${var.github_org}/${var.github_repo}:environment:${env}"]
  )
}

# ======================================================================================
# Trust policy for the terraform_deploy role
# ======================================================================================
data "aws_iam_policy_document" "github_actions_trust_policy" {
  # Emergency access: an admin in the management account can assume this
  # role, but only if they've turned on MFA.
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
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.trusted_environment_subs
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
      # AWS won't delete a role that still has something attached to it.
      # Terraform checks for that before deleting, and this permission is
      # what lets it check — without it, deleting a role fails even though
      # the delete permission itself is right there.
      "iam:ListInstanceProfilesForRole",

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
      "iam:DeletePolicyVersion",
      # Creating a policy WITH tags needs an extra permission beyond just
      # "create" — same pattern you'll see again below for SSM and
      # CloudWatch Logs. This one covers the flow-log delivery role's policy.
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyTags"
    ]
    resources = ["*"]
  }

  # Kept as its own statement on purpose, not merged into ManageInstanceRoles
  # above: AWS treats "I can manage this role" and "I can hand this role to
  # another AWS service to use" as two different permissions — being able to
  # create a role doesn't automatically let you give it away. We need this
  # because creating a flow log means telling EC2 "use this role to write
  # logs", which needs its own explicit permission. resources = ["*"]
  # because the role's name is generated by Terraform, so there's no fixed
  # ID to lock this down to ahead of time — but the condition below still
  # limits it so the role can only be handed to the flow-logs service, not
  # just any AWS service.
  statement {
    sid       = "PassFlowLogDeliveryRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["vpc-flow-logs.amazonaws.com"]
    }
  }

  # Permissions for the encryption key used on flow logs (modules/vpc's
  # aws_kms_key.flow_log / aws_kms_alias.flow_log).
  #
  # Deliberately NOT "kms:*" (every KMS action) — only what's needed to
  # create, read, update, and delete this one key. Notably missing:
  # permission to actually USE the key to encrypt/decrypt anything (this
  # role only manages the key, never reads or writes data with it), and
  # permission to hand out access to it (kms:CreateGrant) — granting that
  # broadly is a well-known way a role can quietly gain access to every KMS
  # key in the account, not just this one. resources = ["*"] is still
  # needed even so: a brand-new key has no ID yet, so there's nothing to
  # scope the permission to at the moment it's created.
  statement {
    sid    = "FlowLogKmsKey"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:EnableKey",
      "kms:DisableKey",
      "kms:UpdateKeyDescription",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ListResourceTags",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:ListAliases",
    ]
    resources = ["*"]
  }

  statement {
    # Used to be VPN-only, but now also covers the flow-log CloudWatch
    # group — both are really just "a CloudWatch log group this account
    # creates", so the same permissions cover either one.
    sid    = "CloudWatchLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup",
      # Creating a log group WITH tags needs its own extra permission —
      # same pattern noted for SSM below.
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
      # Setting the retention period and the encryption key are each their
      # own separate call behind the scenes, not part of CreateLogGroup —
      # so each needs its own permission too.
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:AssociateKmsKey",
      "logs:DisassociateKmsKey"
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
      # Every SSM parameter here gets tags. Tagging one is its own separate
      # call from creating it, so it needs its own permission. UntagResource
      # covers the opposite case — a tag that gets removed later.
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      # Terraform reads back a parameter's current tags on every plan/apply
      # to check they still match the code. This action can be scoped to
      # one specific parameter (unlike DescribeParameters below), so it
      # belongs up here.
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

  # This one can't be scoped to specific parameters at all — it's a
  # search/filter API over the whole parameter store, so AWS always checks
  # it against the whole account, never one parameter. Scoping it up in
  # SSMParameterStore above would look correct but silently grant nothing,
  # so it needs its own wide-open statement instead.
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

  # Access to this account's own Terraform state file in S3 — locked to
  # just this account's own folder, not the whole bucket. Every account has
  # this same statement, each locked to its own folder, so one account's
  # pipeline can never read or touch another account's state.
  # state_key_prefix must match the key used in this account's own backend
  # config.
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

  # ListBucket works differently from GetObject/PutObject — it always
  # targets the whole bucket, never one file's path, so it can't be locked
  # to a folder the same way the statement above is. The s3:prefix
  # condition below is the only way to limit what a ListBucket call sees.
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
      # Same "tag on create" situation as elsewhere: AWS checks this
      # permission before the resource share even has an ID yet, so it
      # can't be scoped to a specific ARN — has to stay wide open.
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
  # Defaults to null (see variables.tf), meaning no boundary — nothing
  # changes for any caller that doesn't set this.
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_iam_openid_connect_provider.github, data.aws_iam_openid_connect_provider.github]
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
      identifiers = [local.github_oidc_provider_arn]
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

# Lets terraform_plan borrow the SSMReadOnly role in the management
# account, just for reading SSM parameters from there while planning.
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

# Same idea as TerraformDeploy's StateFileAccess above, but for the
# read-only plan role, and locked to this account's own folder.
#
# The ReadOnlyAccess policy attached below already grants read access to
# every bucket in the account, so the read actions here are redundant with
# that. What actually matters is write access for state locking
# (PutObject/DeleteObject) — ReadOnlyAccess doesn't grant that, and a
# PR-triggered plan should never be able to write outside its own folder.
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
        # Targets the whole bucket, not one file's path (see
        # ListOwnPrefixOnly above) — listed mainly to mirror Deploy's
        # setup; ReadOnlyAccess already covers this in practice.
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
