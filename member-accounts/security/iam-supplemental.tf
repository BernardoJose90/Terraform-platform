###############################################################################
# Extra IAM (Identity and Access Management) Identity Center / Identity
# Store permissions for the TerraformDeploy role.
#
# The security account is registered as the delegated admin for SSO
# (Single Sign-On) - that's set up in the management account's AWS
# Organizations config. That's why sso.tf runs from here instead of
# from the management account: AWS's own guidance is to keep the
# management account's permissions as minimal as possible.
#
# The base role created by modules/github-oidc-roles doesn't include
# any SSO or Identity Store actions, so this file adds them on top,
# just for this account.
###############################################################################

resource "aws_iam_role_policy" "terraform_deploy_sso_identity_center_access" {
  name = "SSOIdentityCenterAccess"
  role = module.github-oidc-roles.role_name

  # If this policy were deleted, nobody's existing access would break -
  # it would just stop CI (the automated deploy pipeline) from being
  # able to change anything in sso.tf, until someone restores this
  # policy by hand.
  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # These IAM actions all start with "sso:", not "sso-admin:", even
        # though "sso-admin" looks like the right prefix at first glance.
        # "sso-admin" is just the name of the AWS CLI/Terraform
        # provider's underlying code package (ssoadmin) - it's not a
        # valid action prefix. Every one of these calls would be denied
        # if written with that prefix instead.
        Sid    = "SsoAdminPermissionSetsAndAssignments"
        Effect = "Allow"
        Action = [
          "sso:ListInstances",
          "sso:CreatePermissionSet",
          "sso:DeletePermissionSet",
          "sso:DescribePermissionSet",
          "sso:UpdatePermissionSet",
          "sso:ListPermissionSets",
          # Lets Terraform read and write tags on a permission set.
          # ListTagsForResource is called on every plan and apply -
          # that's how Terraform checks the tags still match what it
          # expects. TagResource alone isn't enough, either: removing a
          # tag from var.tags requires UntagResource too.
          "sso:TagResource",
          "sso:UntagResource",
          "sso:ListTagsForResource",
          "sso:AttachManagedPolicyToPermissionSet",
          "sso:DetachManagedPolicyFromPermissionSet",
          "sso:ListManagedPoliciesInPermissionSet",
          # Re-provisioning is what actually pushes a changed permission
          # set out to the accounts it's already assigned to. The
          # Update action on its own only changes the definition - it
          # doesn't push that change out to where it's actually
          # deployed.
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
          # The Terraform provider's own read function calls
          # DescribeGroupMembership, which is a separate API call from
          # GetGroupMembership and GetGroupMembershipId listed just
          # below it - both are needed.
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
