#############################################################################################################
# Account: Production
# Purpose: Live workload hosting for public resources and internal-only services (EKS, RDS, internal ALB)
#  1-containes a TerraformDeploy role for GitHub OIDC, scoped to this account only (no cross-account access)
#  2-contains a VPC module for the production VPC, private-only (no IGW/NAT, egress is centralized in the network account)
#  2-contains a TGW attachment module for the production VPC, attached to the prod_spoke TGW route table in the network account
#  3-contains a TGW route table association and propagation for the production VPC
#  4-contains a default route out of the private subnets to the TGW
#  5-contains a purpose-specific private subnets module for EKS, RDS, internal ALB, and general-purpose private resources, with selective TGW routing
#  6-All cross-account access to the network account is done via a scoped role (TgwSpokeWiringProduction) that can only touch prod_spoke and main TGW route tables, never dev_spoke.
#  7-All TGW IDs and route table IDs are read from SSM parameters published by the network account, no remote state access is needed.
#  8-All resources are gated on var.networking_enabled, so the account can be deployed without networking if desired (e.g., for IAM-only changes).
#  9-All resources are tagged with var.tags, which should include "Environment" = "production" and other relevant tags.
#  10-All modules are sourced from ../../modules, which should be the shared modules directory in the repo.
#  11-All providers are configured with the correct region and allowed_account_ids, and assume roles where needed for cross-account access.
#  12-All moved blocks are included to rename modules and resources without causing Terraform to destroy and recreate them.
#  13-All lifecycle preconditions are included to ensure that the number of private route tables matches the number of AZs, to avoid misconfiguration.
#  14-All resources are using nonsensitive() for SSM parameter values to avoid exposing sensitive data in the plan output.
#  15-All modules and resources are using count or for_each to conditionally create resources based on var.networking_enabled, to allow for flexible deployment scenarios.
#############################################################################################################

terraform {
  required_version = "~> 1.11.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Aligned with network (see member-accounts/network/main.tf). The
      # lock file already resolves to 6.x; this just makes it explicit
      # instead of silently floating on whatever ">= 5.83.0" resolves to.
      version = "~> 6.0"
    }
    # Only used for the time_sleep guard below, working around IAM's eventual
    # consistency when this account's own deploy-role permissions and a
    # resource that needs them are applied in the same run.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "production/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# Provider for reading SSM from the management account (account ID only).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# Needed to construct the TGW spoke-wiring role ARN below.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# Main provider for the production account itself.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]
}

# Assumes a role in the network account scoped to prod_spoke + main only
# (modules/tgw-spoke-wiring-role); this account can never touch
# tgw-dev-spoke-rt. 
provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction"
  }
}

# Published by the network account. Read via the aws.network role instead
# of terraform_remote_state, so this account's plan role never needs S3
# read access to the network account's full state file.
data "aws_ssm_parameter" "tgw_id" {
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "prod_spoke_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/prod_spoke"
}

# The "main" table is the one narrow surface this account shares write
# access to with development, used only to propagate this VPC's own
# return route, never to touch dev_spoke.
data "aws_ssm_parameter" "main_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "production"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "production"
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction",
  ]
}

# module.github-oidc-roles manages this same account's own TerraformDeploy
# role permissions (data.aws_iam_policy_document.permissions in that module).
# When a permissions change and a resource that needs it (e.g. the flow-log
# KMS key below) land in the same apply, Terraform has no dependency edge
# between them and applies both in parallel — the IAM policy update reports
# "Modifications complete" in under a second, but IAM's authorization layer
# is eventually consistent and can lag a few seconds behind that. Hit for
# real here: a KMS CreateKey call failed with AccessDeniedException moments
# after the exact permission it needed had already been added, in the same
# apply. This makes every module below explicitly wait past that
# propagation window rather than relying on timing.
resource "time_sleep" "wait_for_deploy_role_permissions" {
  depends_on      = [module.github-oidc-roles]
  create_duration = "15s"

  # Without this, the wait only ever happens the FIRST time this resource is
  # created — later applies that change the permissions document again (a
  # new action, a new statement) don't touch time_sleep at all, so there's
  # no wait before the next thing that needs the new permission. Hit for
  # real: the KMS fix's own apply waited and succeeded, but the very next
  # apply — adding logs:TagResource for the flow-log CloudWatch group —
  # changed the policy again and had NO wait at all, and failed the same way.
  # Keying off the policy's own hash forces time_sleep to be destroyed and
  # recreated (re-running its wait) on every permissions change, forever.
  triggers = {
    permissions_policy_hash = module.github-oidc-roles.permissions_policy_hash
  }
}

# ============================================================
# PRODUCTION VPC (spoke, private-only). Egress is centralized in the
# network account, so this VPC has no NAT/IGW of its own; the vpc module
# instead adds a 0.0.0.0/0 route to the TGW on every private route table
# (see modules/vpc/main.tf's tgw_id handling).
# ============================================================
module "vpc" {
  count = var.networking_enabled ? 1 : 0

  # Depends on BOTH, not just the sleep: time_sleep only blocks anything
  # when IT has a pending action, and its trigger is a hash of current CODE,
  # not of whether the real AWS policy actually matches it yet. If time_sleep
  # already recreated once (e.g. in an earlier apply where the actual policy
  # PutRolePolicy for some other change failed or hadn't run yet), later
  # applies see "trigger unchanged" and skip waiting entirely — even while
  # module.github-oidc-roles still has a real pending policy change sitting
  # right next to it. Hit for real: a fresh plan clearly showed
  # aws_iam_role_policy.terraform_deploy_policy "will be updated in-place",
  # but the apply went straight to destroying a role needing that exact
  # permission, with no policy-update line ever appearing first. Depending on
  # the module directly is unconditional — it forces ALL of that module's
  # pending actions to finish first, every time, with no matched-hash escape
  # hatch.
  depends_on = [module.github-oidc-roles, time_sleep.wait_for_deploy_role_permissions]

  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  # Explicit rather than left to modules/vpc's default-name fallback (see
  # its variables.tf), matching how network/main.tf names its own subnets.
  # Same names the fallback already produces today (name + "-private-" +
  # az), so this is purely making the naming intentional, not a change —
  # renaming these later, if ever wanted, is just a tag update, not a
  # replacement (subnet/route table Name is a tag, not an immutable
  # attribute).
  private_subnet_names = [for az in var.azs : "production-Twg-private-sub-${az}"]

  enable_nat_gateway = false
  tgw_id             = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  tags = var.tags
}

# TGW attachment. Comes up "available" on its own because the TGW has
# AutoAcceptSharedAttachments = enable; no RAM accepter needed since this
# account and the network account are in the same AWS Organization with
# RAM sharing enabled.
module "tgw_attachment" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-attachment"

  name = "tgw-attach-prod-spoke"
  # Safe: this block is itself gated on the same condition as module.vpc,
  # so when it exists, module.vpc[0] definitely exists too.
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)
  vpc_id     = module.vpc[0].vpc_id
  subnet_ids = module.vpc[0].private_subnet_ids

  tags = var.tags
}

# ============================================================
# TGW route table wiring, spoke-owned. Runs against the network account
# via the aws.network provider (assumes TgwSpokeWiringProduction, scoped
# to only prod_spoke + main).
#
# Associated with prod_spoke only, the table development's traffic never
# reaches, so there's no east-west path between the two environments.
# Propagated into both prod_spoke (so this VPC's own table knows about
# its own attachment, required for propagation to work at all) and main
# (so NAT return traffic from the egress VPC has a route back to this
# VPC). This replaces the old inspected_return static route: propagation
# into main achieves the same thing without needing a firewall attachment.
# ============================================================
resource "aws_ec2_transit_gateway_route_table_association" "tgw_rtb_association" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "main" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.main_route_table_id.value)
}

# ============================================================
# Default route out of the private subnets, via the TGW. Lives here
# rather than in modules/vpc because a route targeting a TGW is only
# valid once the VPC is attached, and the attachment depends on
# modules/vpc, so the module cannot depend on the attachment. depends_on
# below is the whole point of this block's location.
# ============================================================
resource "aws_route" "private_to_tgw" {
  # {} when disabled: module.vpc has zero instances then, so there are no
  # private_route_table_ids to route from anyway.
  for_each = var.networking_enabled ? { for idx, az in var.azs : az => idx } : {}

  # Safe: for_each is {} exactly when networking_enabled is false, so this
  # resource has zero instances and module.vpc[0]/module.tgw_attachment[0]
  # are never evaluated for a nonexistent instance.
  route_table_id         = module.vpc[0].private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  depends_on = [module.tgw_attachment]

  lifecycle {
    precondition {
      condition     = length(module.vpc[0].private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc[0].private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}

# ============================================================
# Purpose-specific private subnets — EKS worker nodes, RDS, an internal
# ALB (reached via CloudFront VPC origins), and a general-purpose private
# tier. Its own module (modules/purpose-subnets) rather than folded into
# modules/vpc: network/development have no reason to know about
# production's own application topology, and this repo's own convention
# is that any structural, parameterized pattern gets its own module —
# see modules/tgw, modules/tgw-attachment, etc.
#
# Only eks and resources get an outbound TGW route — rds and alb
# deliberately don't (a database tier and an internal ALB have no
# business initiating outbound internet traffic).
#
# TEARDOWN FLAG: gated the same as everything else that depends on
# module.vpc[0]/the TGW ID.
# ============================================================
module "prod_purpose_subnets" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/prod-purpose-subnets"

  vpc_id = module.vpc[0].vpc_id
  tgw_id = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  production_workload_subnets = {
    eks = {
      route_table_name = "prod-eks-rtb"
      to_tgw           = true
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.30.0/24", name = "prod-eks-a" }
        b = { az = "eu-west-2b", cidr = "10.20.40.0/24", name = "prod-eks-b" }
      }
    }
    rds = {
      route_table_name = "prod-rds-rtb"
      to_tgw           = false
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.50.0/24", name = "prod-rds-a" }
        b = { az = "eu-west-2b", cidr = "10.20.60.0/24", name = "prod-rds-b" }
      }
    }
    alb = {
      route_table_name = "prod-private-alb-rtb"
      to_tgw           = false
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.70.0/24", name = "prod-alb-a" }
        b = { az = "eu-west-2b", cidr = "10.20.80.0/24", name = "prod-alb-b" }
      }
    }
    resources = {
      route_table_name = "prod-private-resources-rtb"
      to_tgw           = true
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.100.0/24", name = "prod-private-resources" }
      }
    }
  }

  tags = var.tags

  # A route targeting the TGW is only valid once the attachment exists —
  # same reasoning as aws_route.private_to_tgw above.
  depends_on = [module.tgw_attachment]
}

# Renames from fix/fixed_modules_and_veriables_name. Without these,
# Terraform treats the renamed module/resource as new and plans to destroy
# the existing production subnets, route tables, associations and the TGW
# route table association, then recreate them — a real outage, not a
# no-op rename. Remove once applied and state has caught up (see
# 2495070 for the precedent).
moved {
  from = module.purpose_subnets
  to   = module.prod_purpose_subnets
}

moved {
  from = aws_ec2_transit_gateway_route_table_association.this
  to   = aws_ec2_transit_gateway_route_table_association.tgw_rtb_association
}
