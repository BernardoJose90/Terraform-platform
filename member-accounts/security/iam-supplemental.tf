###############################################################################
# Supplemental IAM Identity Center / Identity Store access for TerraformDeploy
#
# security is the delegated administrator for sso.amazonaws.com (registered
# from the management account's AWS Organizations config — see
# aws_organizations_delegated_administrator.identity_center there). SSO
# resource management (permission sets, groups, users, account assignments —
# see sso.tf in this directory) runs from here instead of the management
# account, per AWS's own guidance to minimize what has access to the
# management account rather than widening its automation role.
#
# github-oidc-roles' base permission set (module.github-oidc-roles) has no
# sso-admin/identitystore actions at all, so this fills that in. Actions
# cross-checked against the AWS Service Authorization Reference for
# sso-admin and identitystore, not hand-guessed.
###############################################################################

resource "aws_iam_role_policy" "terraform_deploy_sso_identity_center_access" {
  name = "SSOIdentityCenterAccess"
  role = module.github-oidc-roles.role_name

  # Losing this doesn't break current access, but breaks CI's ability to
  # fix or change anything in sso.tf until it's manually restored — which
  # is exactly what happened once already (see sso.tf's comment).
  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SsoAdminPermissionSetsAndAssignments"
        Effect = "Allow"
        Action = [
          "sso-admin:ListInstances",
          "sso-admin:CreatePermissionSet",
          "sso-admin:DeletePermissionSet",
          "sso-admin:DescribePermissionSet",
          "sso-admin:UpdatePermissionSet",
          "sso-admin:ListPermissionSets",
          "sso-admin:TagResource",
          "sso-admin:AttachManagedPolicyToPermissionSet",
          "sso-admin:DetachManagedPolicyFromPermissionSet",
          "sso-admin:ListManagedPoliciesInPermissionSet",
          "sso-admin:CreateAccountAssignment",
          "sso-admin:DeleteAccountAssignment",
          "sso-admin:DescribeAccountAssignmentCreationStatus",
          "sso-admin:DescribeAccountAssignmentDeletionStatus",
          "sso-admin:ListAccountAssignments",
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
          "identitystore:GetGroupMembership",
          "identitystore:GetGroupMembershipId",
          "identitystore:ListGroupMemberships",
        ]
        Resource = "*"
      }
    ]
  })
}
