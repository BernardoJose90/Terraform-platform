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
    "security_analytics",
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

# Groups
resource "aws_identitystore_group" "administrators" {
  display_name      = "administrators"
  description       = "Platform engineers with full access to all accounts."
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

resource "aws_ssoadmin_account_assignment" "security_team_admin" {
  for_each = {
    security           = local.account_ids_sso["security"]
    security_analytics = local.account_ids_sso["security_analytics"]
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.security_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value
}

resource "aws_ssoadmin_account_assignment" "network_team_network_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.network_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["network"]
}
