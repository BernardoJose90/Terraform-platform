###############################################################################
# IAM Identity Center (SSO)
# Users, Groups, Permission Sets, and Account Assignments
#
# Runs from here (security, the registered IAM Identity Center delegated
# admin) instead of the management account, per AWS's own guidance to
# delegate IIC administration away from the management account rather than
# widening its automation permissions. See the Terraform-Org repo's
# organizations.tf (aws_organizations_delegated_administrator.identity_center)
# and this account's iam-supplemental.tf for the permissions that make this
# possible. Resource bodies are unchanged from where this lived previously,
# same names and IDs, only which account's Terraform manages them changed.
#
# Account IDs are read from the management account's SSM parameter store via
# the aws.management provider (same pattern as security_account_id in
# main.tf).
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
# prevent_destroy on this whole block (permission sets, their managed
# policy attachments, the groups, and the user below): these are the
# foundational "what does AdministratorAccess/NetworkAdministrator/
# ReadOnly even mean, and who is james.admin" definitions. A prior
# incident deleted the user and the network_team group, and (had an AWS
# SCP not blocked it) would have taken the administrator permission set's
# policy attachment and every account's admin assignment with it; recovery
# required a manual break-glass session. None of these should ever be
# destroyed as a side effect of an unrelated change; removing this
# protection should be a deliberate, reviewed step.
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
