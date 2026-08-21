###############################################################################
# Extra IAM Identity Center / Identity Store permissions for TerraformDeploy.
#
# The security account is registered as the delegated admin for SSO
# (set up in management's AWS Organizations config), which is why sso.tf
# runs from here instead of from management — AWS's own guidance is to
# keep management's own permissions as minimal as possible. The base role
# from modules/github-oidc-roles doesn't include any SSO or Identity Store
# actions, so this file adds them on top, just for this account.
##############################################################################

resource "aws_iam_role_policy" "terraform_deploy_sso_identity_center_access" {
  name = "SSOIdentityCenterAccess"
  role = module.github-oidc-roles.role_name

  # Losing this policy wouldn't break anyone's existing access — it would
  # just stop CI from being able to change anything in sso.tf, until
  # someone restores it by hand.
  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # These IAM actions all start with "sso:", not "sso-admin:" — even
        # though "sso-admin" looks like the right prefix at a glance.
        # "sso-admin" is just the name of the AWS CLI/Terraform provider's
        # SDK package (ssoadmin); every one of these calls gets denied if
        # written with that prefix instead.
        Sid    = "SsoAdminPermissionSetsAndAssignments"
        Effect = "Allow"
        Action = [
          "sso:ListInstances",
          "sso:CreatePermissionSet",
          "sso:DeletePermissionSet",
          "sso:DescribePermissionSet",
          "sso:UpdatePermissionSet",
          "sso:ListPermissionSets",
          # Lets it read and write tags on a permission set.
          # ListTagsForResource gets called on every plan and apply (that's
          # how Terraform checks tags are still what it expects), and
          # TagResource alone isn't enough — removing a tag from var.tags
          # needs UntagResource too.
          "sso:TagResource",
          "sso:UntagResource",
          "sso:ListTagsForResource",
          "sso:AttachManagedPolicyToPermissionSet",
          "sso:DetachManagedPolicyFromPermissionSet",
          "sso:ListManagedPoliciesInPermissionSet",
          # Re-provisioning is what actually pushes a changed permission
          # set out to the accounts it's already assigned to — Update on
          # its own only changes the definition, not what's actually
          # deployed anywhere yet.
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
          # The provider's own read function calls DescribeGroupMembership,
          # which is a separate API from GetGroupMembership and
          # GetGroupMembershipId just below it — needs both.
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
