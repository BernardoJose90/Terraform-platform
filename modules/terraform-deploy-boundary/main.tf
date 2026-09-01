# ==========================================================================================================================================================================================
# Because permissions in github-oidc-roles is shared and wide, an account like monitoring
# which has no infrastructure at all yet — still technically holds ec2:*, IAM role creation, RAM sharing, etc.
# purely because it uses the same module as network, which genuinely needs all of that.
# 
# This module doesn't touch the shared policy document(github_actions_trust_policy), Instead, it creates a second, separate IAM policy(permissions boundary) which is attached to the same TerraformDeploy role. 
# AWS enforces both policies(github_actions_trust_policy and terraform_deploy_boundary) at once and only allows what's permitted by both 
# So even though the shared policy(github_actions_trust_policy) still grants ec2:* to every account, an account whose boundary doesn't 
# include enable_vpc_networking = true can never actually use it network accounts related IAM permissions.
# 
# In short: this file answers "of everything that role could possibly do, what should THIS specific account actually be allowed to use."
#
# ==========================================================================================================================================================================================

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "terraform_deploy_boundary" {
  # Read-only on this boundary policy's own resource, so `terraform plan`/
  # `apply` can refresh it on every future run without needing any write
  # access to it. Hardcoded ARN (not a resource attribute reference)
  # because referencing aws_iam_policy.terraform_deploy_boundary.arn from
  # inside its own policy document would be a dependency cycle; IAM policy
  # ARNs are deterministic from account ID + name, so this is safe.
  #
  # Deliberately no write access to this policy (content or attachment) —
  # if TerraformDeploy could edit or detach its own boundary, the boundary
  # wouldn't be a real ceiling. Changing it requires the management
  # break-glass path, same as every other account-security-relevant change.
  statement {
    sid    = "ReadOwnBoundaryPolicy"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/TerraformDeployPermissionsBoundary"]
  }

  # TerraformDeploy and TerraformPlan themselves — modules/github-oidc-roles
  # creates and manages both in every account, including their inline role
  # policies and (for TerraformPlan) its two policy attachments. Scoped to
  # exactly these two role ARNs: TerraformDeploy can manage its own and
  # TerraformPlan's role definitions, but can't create or modify any role
  # outside this pair — closing the same privilege-escalation gap
  # terraform-org's boundary closes for its own fixed role list.
  statement {
    sid    = "ManageOwnDeployAndPlanRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.role_name}",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.plan_role_name}",
    ]
  }

  # TerraformPlanS3Policy — the one standalone customer-managed policy
  # modules/github-oidc-roles creates in every account (attached to
  # TerraformPlan for state-locking write access). Name is fixed by that
  # module, so — unlike a VPC's dynamically-named flow-log role — this can
  # be scoped to an exact ARN.
  statement {
    sid    = "ManageOwnPlanS3Policy"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:DeletePolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyTags",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/TerraformPlanS3Policy"]
  }

  # This account's own GitHub OIDC provider — one per account, one exact
  # URL, so (unlike the roles above) this can be scoped to a single exact
  # ARN rather than left wide.
  statement {
    sid    = "ManageOwnOidcProvider"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }

  # Matches modules/github-oidc-roles' own SSMParameterStore scope exactly
  # — management account's /organizations/* + /transit-gateway/*, and this
  # account's own copies of the same two trees.
  statement {
    sid    = "SSMOrganizationsAndTgwParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/transit-gateway/*",
      "arn:aws:ssm:eu-west-2:${data.aws_caller_identity.current.account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${data.aws_caller_identity.current.account_id}:parameter/transit-gateway/*",
    ]
  }

  # Same as modules/github-oidc-roles' SSMDescribeParameters — this API is
  # a whole-account search/filter, AWS never lets it be scoped to specific
  # parameters, so it has to stay wide even in a boundary meant to narrow
  # things down.
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

  # Only present for an account that actually passes
  # extra_assumable_role_arns to its own github-oidc-roles call (e.g. a
  # spoke assuming its TGW wiring role in the network account) — see that
  # variable's description for why this has to match exactly.
  dynamic "statement" {
    for_each = length(var.extra_assumable_role_arns) > 0 ? [1] : []
    content {
      sid       = "AssumeExtraRoles"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.extra_assumable_role_arns
    }
  }

  # This account's own Terraform state file — locked to just its own
  # folder, matching modules/github-oidc-roles' own StateFileAccess scope.
  statement {
    sid    = "StateFileAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}/${var.state_key_prefix}/*"
    ]
  }

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

  # modules/vpc's VPC/subnet/route-table/TGW-attachment resources — same
  # scope as modules/github-oidc-roles' own NetworkAndCompute statement.
  # Can't be narrowed further than "the whole service": these actions
  # apply to resources that don't exist yet at plan time.
  dynamic "statement" {
    for_each = var.enable_vpc_networking ? [1] : []
    content {
      sid       = "NetworkAndCompute"
      effect    = "Allow"
      actions   = ["ec2:*"]
      resources = ["*"]
    }
  }

  # modules/vpc's upstream terraform-aws-modules/vpc creates a flow-log
  # delivery role with a Terraform-generated name whenever
  # enable_flow_log is set (the module's own default) — unlike the named
  # roles below, there's no fixed ID to scope this to before the role
  # exists, same reasoning as modules/github-oidc-roles' own
  # ManageInstanceRoles statement.
  dynamic "statement" {
    for_each = var.enable_vpc_networking ? [1] : []
    content {
      sid    = "ManageFlowLogDeliveryRole"
      effect = "Allow"
      actions = [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:UpdateRole",
        "iam:UpdateAssumeRolePolicy",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_vpc_networking ? [1] : []
    content {
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
  }

  dynamic "statement" {
    for_each = var.enable_vpc_networking ? [1] : []
    content {
      sid    = "ManageFlowLogCloudWatchPolicy"
      effect = "Allow"
      actions = [
        "iam:CreatePolicy",
        "iam:GetPolicy",
        "iam:DeletePolicy",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:ListPolicyVersions",
        "iam:GetPolicyVersion",
        "iam:TagPolicy",
        "iam:UntagPolicy",
        "iam:ListPolicyTags",
      ]
      resources = ["*"]
    }
  }


  # modules/vpc's flow-log encryption key — manage the key, never use it
  # to encrypt/decrypt, never hand out access to it (no kms:CreateGrant).
  dynamic "statement" {
    for_each = var.enable_vpc_networking ? [1] : []
    content {
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
  }

  dynamic "statement" {
    for_each = var.enable_vpc_networking ? [1] : []
    content {
      sid    = "FlowLogCloudWatchLogGroup"
      effect = "Allow"
      actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DeleteLogGroup",
        "logs:TagResource",
        "logs:UntagResource",
        "logs:ListTagsForResource",
        "logs:PutRetentionPolicy",
        "logs:DeleteRetentionPolicy",
        "logs:AssociateKmsKey",
        "logs:DisassociateKmsKey",
      ]
      resources = ["*"]
    }
  }

  # modules/tgw's RAM resource share — only network turns this on; no
  # other account in this repo does resource sharing.
  dynamic "statement" {
    for_each = var.enable_ram_sharing ? [1] : []
    content {
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
        "ram:TagResource",
        "ram:UntagResource",
        "ram:ListTagsForResource",
      ]
      resources = ["*"]
    }
  }

  # SSO/Identity Store admin — only security turns this on. Mirrors
  # security/iam-supplemental.tf's inline role policy exactly; that file
  # is what actually needs this granted (this just has to be at least as
  # wide, or its applies would start failing against this boundary).
  dynamic "statement" {
    for_each = var.enable_sso_management ? [1] : []
    content {
      sid    = "SsoAdminPermissionSetsAndAssignments"
      effect = "Allow"
      actions = [
        "sso:ListInstances",
        "sso:CreatePermissionSet",
        "sso:DeletePermissionSet",
        "sso:DescribePermissionSet",
        "sso:UpdatePermissionSet",
        "sso:ListPermissionSets",
        "sso:TagResource",
        "sso:UntagResource",
        "sso:ListTagsForResource",
        "sso:AttachManagedPolicyToPermissionSet",
        "sso:DetachManagedPolicyFromPermissionSet",
        "sso:ListManagedPoliciesInPermissionSet",
        "sso:ProvisionPermissionSet",
        "sso:DescribeAccountAssignmentCreationStatus",
        "sso:DescribeAccountAssignmentDeletionStatus",
        "sso:DescribePermissionSetProvisioningStatus",
        "sso:CreateAccountAssignment",
        "sso:DeleteAccountAssignment",
        "sso:ListAccountAssignments",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_sso_management ? [1] : []
    content {
      sid    = "IdentityStoreGroupsUsersMemberships"
      effect = "Allow"
      actions = [
        "identitystore:CreateGroup",
        "identitystore:DeleteGroup",
        "identitystore:DescribeGroup",
        "identitystore:UpdateGroup",
        "identitystore:ListGroups",
        "identitystore:CreateUser",
        "identitystore:DeleteUser",
        "identitystore:DescribeUser",
        "identitystore:UpdateUser",
        "identitystore:ListUsers",
        "identitystore:CreateGroupMembership",
        "identitystore:DeleteGroupMembership",
        "identitystore:DescribeGroupMembership",
        "identitystore:GetGroupMembership",
        "identitystore:GetGroupMembershipId",
        "identitystore:ListGroupMemberships",
      ]
      resources = ["*"]
    }
  }

  # Roles this account manages by exact, known name — e.g. network's two
  # spoke-wiring roles (modules/tgw-spoke-wiring-role), which (unlike the
  # flow-log role above) have fixed names their caller chose, so they can
  # be scoped to exact ARNs instead of left wide.
  dynamic "statement" {
    for_each = length(var.manage_named_roles) > 0 ? [1] : []
    content {
      sid    = "ManageNamedRoles"
      effect = "Allow"
      actions = [
        "iam:GetRole",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:UpdateRole",
        "iam:UpdateAssumeRolePolicy",
      ]
      resources = [
        for name in var.manage_named_roles :
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"
      ]
    }
  }

  # Escape hatch for a genuinely one-off need that doesn't fit any of the
  # toggles above — see extra_policy_json's description. Empty for every
  # account today; prefer adding a new toggle over reaching for this if a
  # second account ever needs the same thing.
  source_policy_documents = var.extra_policy_json != "" ? [var.extra_policy_json] : []
}

resource "aws_iam_policy" "terraform_deploy_boundary" {
  name        = "TerraformDeployPermissionsBoundary"
  description = "Caps TerraformDeploy's effective permissions to what ${var.account_name} actually manages. Not editable by TerraformDeploy itself — see this module's main.tf header."
  policy      = data.aws_iam_policy_document.terraform_deploy_boundary.json

  tags = {
    ManagedBy   = "Terraform"
    AccountName = var.account_name
  }
}
