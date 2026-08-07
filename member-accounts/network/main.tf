###############################################################################
# Account: Network
# Purpose: Centralised egress VPC + Transit Gateway hub for East-West
#          (prod<->dev) and North-South (internet) traffic.
#
# This account never reads spoke state. It publishes tgw_id,
# ram_resource_share_arn, and its route table IDs to SSM, and grants each
# spoke account a narrowly-scoped role (modules/tgw-spoke-wiring-role) to
# wire its own TGW association/propagation/return-route directly. Apply
# order is: this account once, then any spoke account, in any order, one
# apply each — see member-accounts/production|development/main.tf for the
# other half.
###############################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "network/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# -----------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.network_account_id.value]
}

locals {
  # ← ADDED. Spoke CIDRs that need a return path through the egress VPC.
  spoke_cidrs = [var.prod_cidr, var.dev_cidr]

  # ← ADDED. One route per (public route table x spoke CIDR).
  #
  # for_each keys must be known at plan time. The keys below are built from the
  # route table INDEX and the CIDR string — both static config — while the route
  # table ID itself stays in the value, where apply-time values are allowed.
  # Keying directly off public_route_table_ids would produce:
  #   Error: Invalid for_each argument ... cannot be determined until apply
  public_spoke_routes = {
    for pair in setproduct(
      range(length(module.egress_vpc.public_route_table_ids)),
      local.spoke_cidrs
      ) : "${pair[0]}-${pair[1]}" => {
      route_table_id = module.egress_vpc.public_route_table_ids[pair[0]]
      cidr           = pair[1]
    }
  }
}

# -----------------------------------------------------------------------
# GitHub OIDC deploy role for this account
# -----------------------------------------------------------------------
module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "network"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = var.management_account_id
  state_bucket_name     = "james-terraform-state-2026"
  role_name             = "TerraformDeploy"
}

# -----------------------------------------------------------------------
# Egress VPC — 10.10.0.0/16
#   private_subnets = TGW attachment subnets (sub-tgw-egress-a/b)
#   public_subnets  = NAT gateway subnets    (sub-nat-egress-a/b)
# The registry vpc module gives us exactly the route tables the design
# doc calls for: private -> local + 0.0.0.0/0 via NAT (AZ-local),
# public -> local + 0.0.0.0/0 via IGW.
# -----------------------------------------------------------------------
module "egress_vpc" {
  source = "../../modules/vpc"

  name = "egress-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # This is the network account's NAT/egress VPC — the one case where
  # enable_nat_gateway = true and tgw_id is left null (it *is* the
  # egress point, so it doesn't need the module's own route-to-TGW).
  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  single_nat_gateway     = false

  tags = var.tags
}

# -----------------------------------------------------------------------
# ← ADDED: return path, VPC side.
#
# The registry vpc module gives the public route tables "local" plus
# 0.0.0.0/0 -> IGW, and nothing else. When a NAT gateway translates a reply
# back to a spoke address (10.20.x.x / 10.30.x.x) it consults the route table
# of the PUBLIC subnet it lives in, finds no match, and the packet is dropped.
#
# Outbound therefore works and return traffic silently disappears — the failure
# looks like "curl hangs", not like a routing error.
#
# These routes send spoke-destined traffic back into the TGW, where the
# "main" route table (see module.tgw below) already has a route to each
# spoke via propagation.
# -----------------------------------------------------------------------
resource "aws_route" "public_to_spokes" {
  for_each = local.public_spoke_routes

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = module.tgw.tgw_id

  # The TGW attachment must exist before a route can target the TGW.
  depends_on = [module.egress_tgw_attachment]
}

# -----------------------------------------------------------------------
# Transit Gateway (hub) — creates "main" (egress's table, and the one
# narrow surface both spokes share write access to for their return
# route) plus prod_spoke/dev_spoke (each isolated to its own spoke's
# automation only), and shares the TGW to prod/dev via RAM.
# -----------------------------------------------------------------------
module "tgw" {
  source = "../../modules/tgw"

  name            = "core-tgw"
  amazon_side_asn = var.amazon_side_asn

  # Account IDs, not secrets — the SSM parameter data source marks
  # .value sensitive unconditionally, which for_each disallows.
  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.production_account_id.value),
    nonsensitive(data.aws_ssm_parameter.development_account_id.value),
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------
# TGW attachment for the egress VPC itself (this account owns the TGW,
# so no RAM acceptance step is needed for this attachment).
# Associated with the "main" route table — consulted for everything
# entering the TGW from the egress VPC, i.e. all NAT return traffic.
# Both spokes propagate their own attachment into "main" (see
# member-accounts/production|development/main.tf), so that return
# traffic already has a route to whichever spoke it's headed back to —
# without prod_spoke or dev_spoke ever being shared between them.
# -----------------------------------------------------------------------
module "egress_tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "egress"
  tgw_id     = module.tgw.tgw_id
  vpc_id     = module.egress_vpc.vpc_id
  subnet_ids = module.egress_vpc.private_subnet_ids

  tags = var.tags
}

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  transit_gateway_attachment_id  = module.egress_tgw_attachment.attachment_id
  transit_gateway_route_table_id = module.tgw.tgw_route_table_ids["main"]
}

# -----------------------------------------------------------------------
# Default route out of each spoke's own isolated table, straight to the
# egress attachment. This is the only entry either table needs: with no
# shared spoke table and no propagation between prod_spoke and dev_spoke,
# there is no east-west path between the two environments at all — a
# spoke can reach the internet (via egress) and nothing else.
# -----------------------------------------------------------------------
module "routes_prod_spoke" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids["prod_spoke"]

  routes = {
    "0.0.0.0/0" = module.egress_tgw_attachment.attachment_id
  }
}

module "routes_dev_spoke" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids["dev_spoke"]

  routes = {
    "0.0.0.0/0" = module.egress_tgw_attachment.attachment_id
  }
}

# -----------------------------------------------------------------------
# Spoke-owned TGW wiring — publishes what a spoke needs to wire itself in,
# and grants each spoke account a narrowly-scoped role to do that wiring
# directly against this account's TGW route tables.
#
# Why this exists: associations/propagations/return-routes for prod_spoke
# and dev_spoke used to live here, gated on the spoke's attachment ID read
# back via terraform_remote_state. That made this account's plan depend on
# spoke state that in turn depends on this account's own outputs — a cycle
# Terraform can't resolve in one graph, "solved" by wrapping everything in
# try()/count and re-applying this account a third time after both spokes.
# The try() didn't fail loudly when a spoke hadn't been applied yet — it
# silently produced zero resources, which reads as a clean apply.
#
# Now: each spoke assumes its own role below (aws.network provider alias,
# see member-accounts/production|development/main.tf) and creates its own
# association (own spoke table) and propagation (own spoke table + main,
# for the return path). This account never references spoke state again.
#
# Each spoke's role is scoped to its own spoke table plus "main" only —
# never the other spoke's table. "main" is the one table both roles can
# touch, and only to propagate their own attachment's return route; a
# spoke's automation still can't associate, disassociate, or otherwise
# manage the other spoke's presence there beyond that.
# -----------------------------------------------------------------------
resource "aws_ssm_parameter" "tgw_id" {
  name  = "/transit-gateway/id"
  type  = "String"
  value = module.tgw.tgw_id
  tags  = var.tags
}

resource "aws_ssm_parameter" "ram_resource_share_arn" {
  name  = "/transit-gateway/ram_resource_share_arn"
  type  = "String"
  value = module.tgw.ram_resource_share_arn
  tags  = var.tags
}

resource "aws_ssm_parameter" "tgw_route_table_id_main" {
  name  = "/transit-gateway/route_table_ids/main"
  type  = "String"
  value = module.tgw.tgw_route_table_ids["main"]
  tags  = var.tags
}

resource "aws_ssm_parameter" "tgw_route_table_id_prod_spoke" {
  name  = "/transit-gateway/route_table_ids/prod_spoke"
  type  = "String"
  value = module.tgw.tgw_route_table_ids["prod_spoke"]
  tags  = var.tags
}

resource "aws_ssm_parameter" "tgw_route_table_id_dev_spoke" {
  name  = "/transit-gateway/route_table_ids/dev_spoke"
  type  = "String"
  value = module.tgw.tgw_route_table_ids["dev_spoke"]
  tags  = var.tags
}

locals {
  tgw_ssm_parameter_arns = [
    aws_ssm_parameter.tgw_id.arn,
    aws_ssm_parameter.ram_resource_share_arn.arn,
    aws_ssm_parameter.tgw_route_table_id_main.arn,
  ]

  network_account_id = nonsensitive(data.aws_ssm_parameter.network_account_id.value)

  main_route_table_arn = "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${module.tgw.tgw_route_table_ids["main"]}"
}

module "tgw_spoke_wiring_production" {
  source = "../../modules/tgw-spoke-wiring-role"

  name             = "TgwSpokeWiringProduction"
  spoke_account_id = nonsensitive(data.aws_ssm_parameter.production_account_id.value)

  route_table_arns = [
    "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${module.tgw.tgw_route_table_ids["prod_spoke"]}",
    local.main_route_table_arn,
  ]

  ssm_parameter_arns = concat(local.tgw_ssm_parameter_arns, [
    aws_ssm_parameter.tgw_route_table_id_prod_spoke.arn,
  ])

  tags = var.tags
}

module "tgw_spoke_wiring_development" {
  source = "../../modules/tgw-spoke-wiring-role"

  name             = "TgwSpokeWiringDevelopment"
  spoke_account_id = nonsensitive(data.aws_ssm_parameter.development_account_id.value)

  route_table_arns = [
    "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${module.tgw.tgw_route_table_ids["dev_spoke"]}",
    local.main_route_table_arn,
  ]

  ssm_parameter_arns = concat(local.tgw_ssm_parameter_arns, [
    aws_ssm_parameter.tgw_route_table_id_dev_spoke.arn,
  ])

  tags = var.tags
}
