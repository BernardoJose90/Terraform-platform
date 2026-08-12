###############################################################################
# Supplemental IAM Identity Center / Identity Store access for TerraformDeploy
#
# security is the delegated administrator for sso.amazonaws.com (registered
# from the management account's AWS Organizations config; see
# aws_organizations_delegated_administrator.identity_center there). SSO
# resource management (permission sets, groups, users, account assignments,
# see sso.tf in this directory) runs from here instead of the management
# account, per AWS's own guidance to minimize what has access to the
# management account rather than widening its automation role.
#
# github-oidc-roles' base permission set (module.github-oidc-roles) has no
# sso-admin/identitystore actions at all, so this fills that in. Actions
# cross-checked against the AWS Service Authorization Reference for
# sso-admin and identitystore, not hand-guessed.
##############################################################################

resource "aws_iam_role_policy" "terraform_deploy_sso_identity_center_access" {
  name = "SSOIdentityCenterAccess"
  role = module.github-oidc-roles.role_name

  # Losing this doesn't break current access, but breaks CI's ability to
  # fix or change anything in sso.tf until it's manually restored. This is a safety measure to prevent accidental deletion of the policy, which would require manual intervention to restore.
  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # IAM action namespace for this service is "sso:", not "sso-admin:".
        # "sso-admin" is only the AWS CLI module / Terraform provider SDK
        # package name (ssoadmin); every one of these calls is denied under
        # sso-admin: even though it reads like the right prefix.
        Sid    = "SsoAdminPermissionSetsAndAssignments"
        Effect = "Allow"
        Action = [
          "sso:ListInstances",
          "sso:CreatePermissionSet",
          "sso:DeletePermissionSet",
          "sso:DescribePermissionSet",
          "sso:UpdatePermissionSet",
          "sso:ListPermissionSets",
          # Tag read/write on permission sets. ListTagsForResource is read
          # on every plan/apply (tag-reconciliation); TagResource alone
          # isn't enough for the reverse (a tag removed from var.tags).
          "sso:TagResource",
          "sso:UntagResource",
          "sso:ListTagsForResource",
          "sso:AttachManagedPolicyToPermissionSet",
          "sso:DetachManagedPolicyFromPermissionSet",
          "sso:ListManagedPoliciesInPermissionSet",
          # Re-provisioning: AWS only applies a changed permission set to
          # already-assigned accounts once it's re-provisioned; Update alone
          # updates the definition but not what's actually deployed.
          "sso:ProvisionPermissionSet",
          "sso:DescribeAccountAssignmentCreationStatus",
          "sso:DescribeAccountAssignmentDeletionStatus",
          "sso:DescribePermissionSetProvisioningStatus",
          "sso:CreateAccountAssignment",
          "sso:DeleteAccountAssignment",
          "sso:ListAccountAssignments",
        ]
        Resource = "*"
      },
      {
        Sid    = "IdentityStoreGroupsUsersMemberships"
        Effect = "Allow"
        Action = [
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
          # The provider's Read function calls DescribeGroupMembership, a
          # separate API from GetGroupMembership/GetGroupMembershipId below.
          "identitystore:DescribeGroupMembership",
          "identitystore:GetGroupMembership",
          "identitystore:GetGroupMembershipId",
          "identitystore:ListGroupMemberships",
        ]
        Resource = "*"
      }
    ]
  })
}
