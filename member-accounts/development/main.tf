###############################################################################
# Account: Development
# Purpose: Dev workload hosting
###############################################################################

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Aligned with network and production (see their main.tf). The lock
      # file already resolves to 6.x; this just makes it explicit instead
      # of silently floating on whatever ">= 5.83.0" happens to resolve to.
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "development/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# Provider for reading SSM from the management account (cross-account role).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}


data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# Needed to construct the TGW spoke-wiring role ARN below.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# Main provider for the development account itself, no profile needed.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.development_account_id.value]

}

# Assumes a role in the network account that's locked to just this
# account's own route table plus "main" (modules/tgw-spoke-wiring-role) —
# this account can never touch production's route table. See
# member-accounts/network/main.tf for the other half of this setup.
#
# The assume_role is only present while wired into the TGW. Detached
# (local.tgw_wiring = false) the provider falls back to this account's own
# credentials and nothing ever uses it — which is what lets an isolated
# development VPC run with no dependency on the network account at all,
# and without every plan trying to assume a cross-account role it doesn't
# need.
provider "aws" {
  alias  = "network"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = local.tgw_wiring ? [1] : []
    content {
      role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringDevelopment"
    }
  }
}

# TGW plumbing published by the network account. Only read when this
# account is actually wired into the TGW (local.tgw_wiring) — a standalone
# isolated VPC has no need for any of it and shouldn't depend on the
# network account being up.
data "aws_ssm_parameter" "tgw_id" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "dev_spoke_route_table_id" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/dev_spoke"
}

# "main" is the one shared table this account and production both get
# write access to — used only so each can publish its own return route,
# never to reach into the other's own table.
data "aws_ssm_parameter" "main_route_table_id" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

locals {
  # The VPC (var.networking_enabled) and the TGW attachment
  # (var.tgw_attachment_enabled) are gated separately, so development can
  # run a standalone isolated VPC with no dependency on the network
  # account. Everything that talks to the network account keys off this.
  tgw_wiring = var.networking_enabled && var.tgw_attachment_enabled

  # Defined once, referenced by both modules below, so they can never
  # silently drift apart the way two hand-typed copies could. Kept
  # unconditional on purpose: it only reads the network account ID from
  # the management account (aws.management), not the TGW itself, and
  # changing it would alter TerraformDeploy's permissions boundary — a
  # separate, more involved change.
  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringDevelopment",
  ]
}

module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "development"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "development"
  role_name             = "TerraformDeploy"

  # See production/main.tf's boundary comment for the full reasoning;
  # this account's infrastructure shape (module.vpc, module.tgw_attachment
  # below) is the same, minus prod-purpose-subnets.
  enable_vpc_networking = true

  extra_assumable_role_arns = local.extra_assumable_role_arns
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "development"


  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"


  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "development"
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = local.extra_assumable_role_arns

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}

# ============================================================
# DEVELOPMENT VPC — private only. When wired to the TGW (tgw_attachment_
# enabled = true) outbound traffic leaves via the network account and the
# catch-all route is added further down. When detached, it's a fully
# isolated VPC: no NAT, no IGW, no default route at all.
# ============================================================
module "vpc" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/vpc"

  # This VPC and module.github-oidc-roles (which sets up this account's
  # own CI permissions) can sometimes run at the same time and collide —
  # AWS doesn't make a permission change visible everywhere instantly.
  # If that happens, the fix is a retry step in
  # .github/workflows/terraform-apply.yaml, not something added here.
  name = "development-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  enable_nat_gateway = false
  # Set only while wired into the TGW. Null when detached — paired with
  # allow_no_default_route below so the module permits a route-less VPC.
  tgw_id                 = local.tgw_wiring ? nonsensitive(data.aws_ssm_parameter.tgw_id[0].value) : null
  allow_no_default_route = !local.tgw_wiring

  tags = var.tags
}

# This account and network are in the same AWS Organization with sharing
# turned on, so the TGW connection gets approved automatically — no
# separate invitation step needed.
module "tgw_attachment" {
  count = local.tgw_wiring ? 1 : 0

  source = "../../modules/tgw-attachment"

  name = "dev-spoke"
  # local.tgw_wiring implies var.networking_enabled, so module.vpc[0]
  # definitely exists whenever this block does — safe to reference below.
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id[0].value)
  vpc_id     = module.vpc[0].vpc_id
  subnet_ids = module.vpc[0].private_subnet_ids

  tags = var.tags
}

# ============================================================
# This wires the VPC into the TGW's routing, run against the network
# account using the scoped-down role from above. Only linked to this
# account's own route table (dev_spoke) — there's no direct path between
# development and production traffic. Also propagated (announced as a
# valid route) into dev_spoke itself, which the link needs to work at
# all, and into "main", so return traffic from NAT can find its way back
# here.
# ============================================================
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  count = local.tgw_wiring ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.dev_spoke_route_table_id[0].value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  count = local.tgw_wiring ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.dev_spoke_route_table_id[0].value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "main" {
  count = local.tgw_wiring ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.main_route_table_id[0].value)
}

# ============================================================
# Sends outbound traffic from the private subnets to the TGW. This has
# to live here rather than inside modules/vpc: a route can't point at
# the TGW until the VPC is actually connected to it, and that connection
# is created AFTER modules/vpc runs — so modules/vpc has no way to wait
# for something that doesn't exist yet when it runs. depends_on below is
# the entire reason this lives out here instead.
#
# for_each is built from var.azs (known up front), not from the private
# route table IDs (only known after the VPC is actually created) —
# keying off those directly would fail with "cannot be determined until
# apply".
# ============================================================

resource "aws_route" "private_to_tgw" {
  # Empty unless this account is wired into the TGW — an isolated VPC has
  # no default route by design, and module.tgw_attachment doesn't exist
  # then either.
  for_each = local.tgw_wiring ? { for idx, az in var.azs : az => idx } : {}

  # Safe to reference module.vpc[0]/module.tgw_attachment[0] here: this
  # whole resource is empty exactly when the TGW wiring is off, so it
  # never actually tries to look at either one when they don't exist.
  route_table_id         = module.vpc[0].private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id[0].value)

  depends_on = [module.tgw_attachment]

  lifecycle {
    precondition {
      condition     = length(module.vpc[0].private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc[0].private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}
