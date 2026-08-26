# =====================================================================================================================================================================
# This is the module that creates the IAM identities GitHub Actions uses to run Terraform solving two problems:

# 1. Secure login (authentication), with no stored secrets.
# It creates an OIDC trust relationship between AWS and GitHub — GitHub proves its identity with a short-lived token on every workflow run, 
# instead of a long-lived AWS access key sitting in a GitHub secret forever (which would be a standing target if ever leaked). 
# The trust policy is scoped tightly: only specific GitHub Environment names (production-approval, automated, teardown-approval) 
# are trusted, plus a break-glass path for a human with MFA in the management account.

# 2. What that identity is allowed to do (authorization).
# Once logged in, the role needs permissions to actually create/manage infrastructure — VPCs, TGW attachments, IAM roles it needs to hand off to other AWS services, 
# SSM parameters, its own state file in S3, etc. That's the permissions policy document in this file — one shared, wide policy, 
# written to cover whatever any account calling this module might need (since network needs far more than monitoring does, but they both call the same module).
#   
# It also creates a second, read-only role (TerraformPlan) for PR-time plans, so a plan run can never accidentally write anything.
# =======================================================================================================================================================================

# Data source block — a read-only lookup, which asks AWS: "who am I, right now, in this Terraform run?"
# it returns three things about whichever AWS account/credentials Terraform is currently authenticated as:
# account_id — the 12-digit AWS account number
# arn — the full ARN of the identity being used
# user_id — a unique identifier for that identity
data "aws_caller_identity" "read_current_account" {}

# ====================================================================================================================
# Resource block - creates a Github Provider this is what lets AWS trust a token from GitHub Actions, instead of
# needing a stored access key. Every caller(dev, prod security etc) creates and owns its own provider.
# also added prevent_destroy because every account's ability to log in via GitHub Actions depends on this staying put.
# ====================================================================================================================
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

# locals is just a block of named shortcuts which are values computed once, 
# then reused by name later in the file, instead of writing out the full expression every time. 
locals {
  # This is just a short alias for the OIDC provider resource's ARN
  # used in the TerraformDeploy & TerraformPlan trust_policy below in the GitHubActionsCI statement, 
  # so we don't have to write out the full resource reference every time.
  github_oidc_provider_arn = aws_iam_openid_connect_provider.github.arn

  # Every caller trusts these three GitHub Environments.
  # allow-list of which three GitHub Environments are trusted to log in as this role. 
  trusted_environment_subs = [
    "repo:${var.github_org}/${var.github_repo}:environment:production-approval",
    "repo:${var.github_org}/${var.github_repo}:environment:automated",
    "repo:${var.github_org}/${var.github_repo}:environment:teardown-approval",
  ]
}

# ======================================================================================
# Trust policy for the terraform_deploy role it answers who is allowed to log in as this role at all?
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
      "iam:PutRolePermissionsBoundary",
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
# 
# resource block - creates the TerraformDeploy role, which is the identity GitHub Actions uses to run Terraform.
resource "aws_iam_role" "terraform_deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.github_actions_trust_policy.json
  max_session_duration = 3600
  # Defaults to null, meaning no boundary — nothing changes for any caller
  # that doesn't set this. Re-added 2026-08-25: this was removed the same
  # day terraform-org stopped calling this module (its sole caller at the
  # time), but every in-repo account is now adopting a boundary of its
  # own via modules/terraform-deploy-boundary, so it's needed here again.
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  lifecycle {
    prevent_destroy = true
  }

}

resource "aws_iam_role_policy" "terraform_deploy_policy" {
  name   = "TerraformDeployPermissions"
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

# ======================================================================================
# Trust policy for the terraform_plan role it answers who is allowed to log in as this role at all? 
# this role is used for PR-time plans, so it can read resources but not modify them. 
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

# This resource block grants the read-only TerraformPlan role permission to assume a role in another account (whatever's in extra_assumable_role_arns)
# but only for accounts that actually pass something in that list which in our case like for production account below
#   extra_assumable_role_arns = [
#     "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction",
#   ]. 
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
# This resource block attaches the AWS-managed ReadOnlyAccess policy to the terraform_plan role, so it can read resources but not modify them.
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

# This policy is scoped to just this account's own folder, so one account's
# plan role can never write to another account's state.
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

# This is the attachment of the S3 policy to the terraform_plan role, so it can read/write its own state folder.
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
