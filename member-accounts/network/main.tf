###############################################################################
# Account: Network
# Purpose: Centralised egress VPC + Transit Gateway-attached Network Firewall
#          for inspected East-West (prod<->dev) and North-South (internet)
#          traffic. See DEPLOYMENT_NOTES.md for the apply order — this
#          config has a real cross-account dependency and needs 3 applies.
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

# -----------------------------------------------------------------------
# Remote state — read spoke VPC attachment IDs once they exist in the
# production / development accounts. On the very first apply of this
# account these outputs won't exist yet, so every reference below is
# wrapped in try()/count so the rest of the network account can still
# stand up. Re-apply this account after production + development have
# been applied to wire up the spoke associations & routes.
# -----------------------------------------------------------------------
data "terraform_remote_state" "production" {
  backend = "s3"
  config = {
    bucket = "james-terraform-state-2026"
    key    = "production/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "development" {
  backend = "s3"
  config = {
    bucket = "james-terraform-state-2026"
    key    = "development/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  prod_attachment_id = try(data.terraform_remote_state.production.outputs.tgw_attachment_id, null)
  dev_attachment_id  = try(data.terraform_remote_state.development.outputs.tgw_attachment_id, null)

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
# These routes send spoke-destined traffic back into the TGW, where the "main"
# route table (see module.routes_main below) forwards it to the firewall.
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
# Transit Gateway (hub) — creates the 4 route tables (main,
# firewall_forwarding, prod_spoke, dev_spoke) and shares the TGW to
# prod/dev via RAM.
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
# Associated with the "main" route table — which is NOT unused: it is the
# table consulted for everything entering the TGW from the egress VPC,
# i.e. all return traffic. See module.routes_main below.
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
# Network Firewall — native TGW network function attachment. The module
# also associates the firewall's own attachment with the
# firewall_forwarding route table.
# -----------------------------------------------------------------------
module "network_firewall" {
  source = "../../modules/network-firewall"

  name               = "cross-env-inspection"
  tgw_id             = module.tgw.tgw_id
  availability_zones = var.azs

  tgw_firewall_forwarding_route_table_id = module.tgw.tgw_route_table_ids["firewall_forwarding"]

  prod_cidr = var.prod_cidr
  dev_cidr  = var.dev_cidr

  tags = var.tags
}

# -----------------------------------------------------------------------
# Spoke associations + local-CIDR propagation.
# Each spoke's own VPC route is *propagated* automatically; everything
# else in that spoke's route table is a static route to the firewall
# (below), forcing pre-inspection routing for all other traffic.
# -----------------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table_association" "prod_spoke" {
  count                          = local.prod_attachment_id != null ? 1 : 0
  transit_gateway_attachment_id  = local.prod_attachment_id
  transit_gateway_route_table_id = module.tgw.tgw_route_table_ids["prod_spoke"]
}

resource "aws_ec2_transit_gateway_route_table_propagation" "prod_spoke" {
  count                          = local.prod_attachment_id != null ? 1 : 0
  transit_gateway_attachment_id  = local.prod_attachment_id
  transit_gateway_route_table_id = module.tgw.tgw_route_table_ids["prod_spoke"]
}

resource "aws_ec2_transit_gateway_route_table_association" "dev_spoke" {
  count                          = local.dev_attachment_id != null ? 1 : 0
  transit_gateway_attachment_id  = local.dev_attachment_id
  transit_gateway_route_table_id = module.tgw.tgw_route_table_ids["dev_spoke"]
}

resource "aws_ec2_transit_gateway_route_table_propagation" "dev_spoke" {
  count                          = local.dev_attachment_id != null ? 1 : 0
  transit_gateway_attachment_id  = local.dev_attachment_id
  transit_gateway_route_table_id = module.tgw.tgw_route_table_ids["dev_spoke"]
}

# -----------------------------------------------------------------------
# Static routes — pre-inspection (prod/dev -> firewall) and
# post-inspection (firewall -> final destination), exactly as laid
# out in the design doc's TGW Routes tables.
# -----------------------------------------------------------------------
module "routes_prod_spoke" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids["prod_spoke"]

  routes = {
    "0.0.0.0/0"    = module.network_firewall.tgw_attachment_id
    "10.10.0.0/16" = module.network_firewall.tgw_attachment_id
    "10.30.0.0/16" = module.network_firewall.tgw_attachment_id
  }
}

module "routes_dev_spoke" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids["dev_spoke"]

  routes = {
    "0.0.0.0/0"    = module.network_firewall.tgw_attachment_id
    "10.10.0.0/16" = module.network_firewall.tgw_attachment_id
    "10.20.0.0/16" = module.network_firewall.tgw_attachment_id
  }
}

module "routes_firewall_forwarding" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids["firewall_forwarding"]

  routes = merge(
    local.prod_attachment_id != null ? { "10.20.0.0/16" = local.prod_attachment_id } : {},
    local.dev_attachment_id != null ? { "10.30.0.0/16" = local.dev_attachment_id } : {},
    { "0.0.0.0/0" = module.egress_tgw_attachment.attachment_id }
  )
}

# -----------------------------------------------------------------------
# ← ADDED: return path, TGW side.
#
# The "main" route table is associated with the egress VPC attachment, so it is
# consulted for every packet the TGW receives from the egress VPC — which is all
# return traffic coming back through the NAT gateways. It currently has no routes
# at all, so that traffic is dropped at the TGW.
#
# These point at the FIREWALL attachment rather than straight at the spokes.
# That is deliberate: sending returns via the firewall keeps inspection
# symmetric, so the stateful engine sees both directions of every flow. The rule
# group uses direction = ANY, and asymmetric routing produces flows a stateful
# engine cannot track correctly.
#
# Guarded on the same locals as the spoke associations above, so the first apply
# of this account (before prod/dev exist) still succeeds.
# -----------------------------------------------------------------------
module "routes_main" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids["main"]

  routes = merge(
    local.prod_attachment_id != null ? { "10.20.0.0/16" = module.network_firewall.tgw_attachment_id } : {},
    local.dev_attachment_id != null ? { "10.30.0.0/16" = module.network_firewall.tgw_attachment_id } : {},
  )
}
