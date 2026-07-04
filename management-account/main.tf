###############################################################################
# Account: Management (145678291484)
# Purpose: this main.tf files sets up SSO/identity after accounts exist IAM Identity Center — users, groups, permission sets,
#          and account assignments managed as code this basicaly Sets up who can access those accounts (SSO permissions).
#
# FIRST-TIME SETUP — import existing resources before applying:
#
#   # Import the existing permission sets
#   terraform import 'aws_ssoadmin_permission_set.administrator' \
#     'arn:aws:sso:::permissionSet/ssoins-75359166bd3ea230/ps-75356fbf561cf5e4,arn:aws:sso:::instance/ssoins-75359166bd3ea230'
#
#   terraform import 'aws_ssoadmin_permission_set.network_administrator' \
#     'arn:aws:sso:::permissionSet/ssoins-75359166bd3ea230/ps-7535a851e33ad3b2,arn:aws:sso:::instance/ssoins-75359166bd3ea230'
#
#   # Import existing groups
#   terraform import 'aws_identitystore_group.administrators' \
#     'd-9c674a5d65/76824244-0001-7040-b125-b0a4806c0e1f'
#
#   terraform import 'aws_identitystore_group.security_team' \
#     'd-9c674a5d65/96124274-f061-70e4-2d49-1fc88dd2c03c'
#
#   terraform import 'aws_identitystore_group.network_team' \
#     'd-9c674a5d65/f6d292e4-e0b1-7026-1b27-8c46609f6b6e'
#
#   # Import existing user
#   terraform import 'aws_identitystore_user.james_admin' \
#     'd-9c674a5d65/5612e2c4-e021-70bb-4523-5bf714cdfec6'
###############################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "james-terraform-state-2026"
    key            = "management/terraform.tfstate"
    region         = "eu-west-2"
    use_lockfile = true
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}


###############################################################################
# 1. Data source — IAM Identity Center instance
# Looks up your existing SSO instance automatically.
###############################################################################
data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id     = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  # Define the list of account names we need
  account_names = [
    "security",
    "security_analytics",
    "network",
    "monitoring",
    "production",
    "development"
  ]
}

###############################################################################
# 2. Data sources — Fetch account IDs from SSM Parameter Store
# These are written by the terraform-org repository during its apply.
###############################################################################
data "aws_ssm_parameter" "account_ids" {
  for_each = toset(local.account_names)
  name     = "/organizations/accounts/${each.value}"
}

# Build the account_ids map from SSM parameters
locals {
  # ✅ Read account IDs from SSM (the secure way)
  account_ids = {
    for name in local.account_names :
    name => data.aws_ssm_parameter.account_ids[name].value
  }
}

###############################################################################
# 3. Permission Sets
# Defines WHAT level of access is granted.
###############################################################################

# AdministratorAccess — full access, used for platform engineers
resource "aws_ssoadmin_permission_set" "administrator" {
  name             = "AdministratorAccess"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Full administrator access. For platform engineers only."

  tags = { ManagedBy = "Terraform" }
}

# Attach AWS managed AdministratorAccess policy
resource "aws_ssoadmin_managed_policy_attachment" "administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# NetworkAdministrator — network-specific access
resource "aws_ssoadmin_permission_set" "network_administrator" {
  name             = "NetworkAdministrator"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Network administration access. For network team."

  tags = { ManagedBy = "Terraform" }
}

# Attach AWS managed NetworkAdministrator policy
resource "aws_ssoadmin_managed_policy_attachment" "network_administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/job-function/NetworkAdministrator"
}

# ReadOnly — read-only access, used for developers in production
resource "aws_ssoadmin_permission_set" "read_only" {
  name             = "ReadOnly"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT1H"
  description      = "Read-only access. For developers viewing production."

  tags = { ManagedBy = "Terraform" }
}

resource "aws_ssoadmin_managed_policy_attachment" "read_only" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

###############################################################################
# 4. Groups
# Defines WHO gets access. Assign users to groups, not directly to accounts.
# This is the AWS recommended pattern — it scales as your team grows.
###############################################################################

resource "aws_identitystore_group" "administrators" {
  display_name      = "administrators"
  description       = "Platform engineers with full access to all accounts."
  identity_store_id = local.identity_store_id
}

resource "aws_identitystore_group" "security_team" {
  display_name      = "Security Team"
  description       = "Security engineers with access to security accounts."
  identity_store_id = local.identity_store_id
}

resource "aws_identitystore_group" "network_team" {
  display_name      = "Network Team"
  description       = "Network engineers with access to network account."
  identity_store_id = local.identity_store_id
}

###############################################################################
# 5. Users
###############################################################################

resource "aws_identitystore_user" "james_admin" {
  identity_store_id = local.identity_store_id

  display_name = "james jose"
  user_name    = "james.admin"

  name {
    given_name  = "james"
    family_name = "jose"
  }

  emails {
    value   = "james.jose109099+aws-mgemt@gmail.com"
    type    = "work"
    primary = true
  }
}

###############################################################################
# 6. Group Memberships
# Add james.admin to all groups — he is the only user right now.
# Add more users here as your team grows.
###############################################################################

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

###############################################################################
# 7. Account Assignments
# Defines WHERE each group can access and with WHAT permission set.
#
# Pattern:
#   administrators → AdministratorAccess  → all accounts
#   security_team  → AdministratorAccess  → security accounts only
#   network_team   → NetworkAdministrator → network account only
#   administrators → ReadOnly             → production (extra safety)
###############################################################################

# implemented the AWS best practice of giving administrators both full admin and read-only access to production
# 1️⃣ Administrators → Full Admin → ALL accounts
resource "aws_ssoadmin_account_assignment" "administrators_admin" {
  for_each = local.account_ids

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.administrators.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value
}

# 2️⃣ Administrators → Read-Only → Production (Safety net!) 
resource "aws_ssoadmin_account_assignment" "administrators_readonly_prod" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.administrators.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids["production"]
}

# security_team group → AdministratorAccess → security + security-analytics
resource "aws_ssoadmin_account_assignment" "security_team_admin" {
  for_each = {
    security           = local.account_ids["security"]
    security_analytics = local.account_ids["security_analytics"]
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn

  principal_type = "GROUP"
  principal_id   = aws_identitystore_group.security_team.group_id

  target_type = "AWS_ACCOUNT"
  target_id   = each.value
}

# network_team group → NetworkAdministrator → network account only
resource "aws_ssoadmin_account_assignment" "network_team_network_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn

  principal_type = "GROUP"
  principal_id   = aws_identitystore_group.network_team.group_id

  target_type = "AWS_ACCOUNT"
  target_id   = local.account_ids["network"]
}