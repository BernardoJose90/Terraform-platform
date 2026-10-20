###############################################################################
# IAM (Identity and Access Management) Identity Center, also known as
# SSO (Single Sign-On): this file defines users, groups, permission
# sets, and who gets assigned what access.
#
# This runs from the security account rather than the management
# account. That's the "delegated admin" setup that AWS itself
# recommends, so the management account's own permissions can stay as
# minimal as possible. See Terraform-Org's organizations.tf and this
# account's iam-supplemental.tf for the permissions that make this
# possible. Account IDs are read from SSM (Systems Manager) parameters
# published by the management account, via the aws.management provider.
###############################################################################

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  sso_account_names = [
    "security",
    "infra_shared_services",
    "network",
    "monitoring",
    "production",
    "development"
  ]
}

data "aws_ssm_parameter" "account_ids_sso" {
  for_each = toset(local.sso_account_names)
  provider = aws.management
  name     = "/organizations/accounts/${each.value}"
}

locals {
  account_ids_sso = {
    for name in local.sso_account_names :
    name => data.aws_ssm_parameter.account_ids_sso[name].value
  }
}

# Permission Sets
#
# Everything in this block - permission sets, policy attachments,
# groups, and the user below - has prevent_destroy set on it. This
# isn't just a precaution: it already happened once for real. A past
# incident accidentally deleted the admin user and the network_team
# group. It would have also deleted the admin permission set and every
# account's admin access along with it, except that an SCP (Service
# Control Policy - an organization-wide guardrail policy) happened to
# block that part. Recovering from it required a manual "break-glass"
# session (emergency access granted outside the normal process).
#
# Because of that history, removing this protection should always be a
# deliberate, reviewed decision - never something that happens by
# accident.
resource "aws_ssoadmin_permission_set" "administrator" {
  name             = "AdministratorAccess"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Full administrator access. For platform engineers only."
  tags             = { ManagedBy = "Terraform" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_permission_set" "EKS-Admin" {
  name             = "EKS-Admin"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Full EKS cluster administrator access. For platform engineers only."
  tags             = { ManagedBy = "Terraform" }

  lifecycle {
    prevent_destroy = true
  }
}

# Inline policy (not a managed AWS policy, so it uses a different resource
# type than the aws_ssoadmin_managed_policy_attachment blocks above) - lets
# holders generate a kubeconfig and actually use it against the cluster.
# eks:AccessKubernetesApi is the one that's easy to miss: DescribeCluster
# alone only lets you read cluster metadata (enough to build a kubeconfig
# file), not call the cluster's Kubernetes API with it.
resource "aws_ssoadmin_permission_set_inline_policy" "eks_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.EKS-Admin.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # DescribeClusterVersions, ListFargateProfiles, DescribeNodegroup,
        # ListNodegroups, ListUpdates, ListAddons, DescribeAddonVersions,
        # and ListIdentityProviderConfigs aren't needed for kubectl access
        # itself - they're what the EKS console's Resources/Nodes/version
        # panels call to render, per AWS's own documented required-permissions
        # list: https://docs.aws.amazon.com/eks/latest/userguide/view-kubernetes-resources.html
        Sid    = "EksClusterAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi",
          "eks:DescribeClusterVersions",
          "eks:ListFargateProfiles",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups",
          "eks:ListUpdates",
          "eks:ListAddons",
          "eks:ListAccessEntries",
          "eks:ListCapabilities",
          "eks:ListPodIdentityAssociations",
          "eks:ListAccessEntries",
          "aps:ListScrapers",
          "eks:ListInsights",
          "eks:DescribeAddonVersions",
          "backup:ListBackupJobs",
          "cloudwatch:GetMetricData",
          "networkflowmonitor:ListMonitors",
          "eks:ListIdentityProviderConfigs"
        ]
        Resource = "*"
      },
      {
        # Same AWS-documented list above also calls this - the console
        # shows the cluster's IAM role by name, which needs a way to look
        # up roles across the account rather than one it already knows.
        Sid    = "EksConsoleIamRoleLookup"
        Effect = "Allow"
        Action = [
          "iam:ListRoles"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_ssoadmin_managed_policy_attachment" "administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_permission_set" "network_administrator" {
  name             = "NetworkAdministrator"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Network administration access. For network team."
  tags             = { ManagedBy = "Terraform" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_managed_policy_attachment" "network_administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/job-function/NetworkAdministrator"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_permission_set" "read_only" {
  name             = "ReadOnly"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT1H"
  description      = "Read-only access. For developers viewing production."
  tags             = { ManagedBy = "Terraform" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_managed_policy_attachment" "read_only" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"

  lifecycle {
    prevent_destroy = true
  }
}

# Group: Administrators.
resource "aws_identitystore_group" "administrators" {
  display_name      = "administrators"
  description       = "Platform engineers with full access to all accounts."
  identity_store_id = local.identity_store_id

  lifecycle {
    prevent_destroy = true
  }
}

# Groups: platform-admins for EKS cluster admin access.
resource "aws_identitystore_group" "platform-admins" {
  display_name      = "platform-admins"
  description       = "Platform engineers with full EKS access to all accounts. This group is used for EKS cluster admin access."
  identity_store_id = local.identity_store_id

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_identitystore_group" "security_team" {
  display_name      = "Security Team"
  description       = "Security engineers with access to security accounts."
  identity_store_id = local.identity_store_id

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_identitystore_group" "network_team" {
  display_name      = "Network Team"
  description       = "Network engineers with access to network account."
  identity_store_id = local.identity_store_id

  lifecycle {
    prevent_destroy = true
  }
}

# adds james.admin as a member of the platform-admins group in AWS Identity Center (SSO).
resource "aws_identitystore_group_membership" "james_platform_admins" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.platform-admins.group_id
  member_id         = aws_identitystore_user.james_admin.user_id

  lifecycle {
    prevent_destroy = true
  }
}


# Users
resource "aws_identitystore_user" "james_admin" {
  identity_store_id = local.identity_store_id
  display_name      = "james jose"
  user_name         = "james.admin"
  name {
    given_name  = "james"
    family_name = "jose"
  }
  emails {
    value   = "james.jose109099+aws-mgemt@gmail.com"
    type    = "work"
    primary = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Group Memberships
resource "aws_identitystore_group_membership" "james_administrators" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.administrators.group_id
  member_id         = aws_identitystore_user.james_admin.user_id
}

resource "aws_identitystore_group_membership" "james_security_team" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.security_team.group_id
  member_id         = aws_identitystore_user.james_admin.user_id
}

resource "aws_identitystore_group_membership" "james_network_team" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.network_team.group_id
  member_id         = aws_identitystore_user.james_admin.user_id
}

# Account Assignments
resource "aws_ssoadmin_account_assignment" "administrators_admin" {
  for_each = local.account_ids_sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.administrators.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value
}

resource "aws_ssoadmin_account_assignment" "administrators_readonly_prod" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.administrators.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["production"]
}

moved {
  from = aws_ssoadmin_account_assignment.security_team_admin["security"]
  to   = aws_ssoadmin_account_assignment.security_team_admin
}

resource "aws_ssoadmin_account_assignment" "security_team_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.security_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["security"]
}

resource "aws_ssoadmin_account_assignment" "network_team_network_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.network_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["network"]
}

resource "aws_ssoadmin_account_assignment" "platform_admins_eks_admin_Dev" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.EKS-Admin.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.platform-admins.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["development"]
}

resource "aws_ssoadmin_account_assignment" "platform_admins_eks_admin_prod" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.EKS-Admin.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.platform-admins.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["production"]
}
