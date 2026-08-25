########################################################################################
# Account: Network
# Egress VPC + Transit Gateway + NAT for all spoke accounts, plus the
# shared "main" TGW route table both spokes propagate their return route
# into. Never reads spoke state — publishes tgw_id, ram_resource_share_arn,
# and route table IDs to SSM, and grants each spoke a narrow role
# (modules/tgw-spoke-wiring-role) to wire itself in. Apply this account
# once first, then either spoke, any order.
#######################################################################################

terraform {
  required_version = "~> 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Used by modules/tgw's wait-for-available poll (null_resource +
    # local-exec) — see the comment above that resource for why it's
    # needed at all.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
  # Spoke CIDRs that need a return path through the egress VPC.
  spoke_cidrs = [var.prod_cidr, var.dev_cidr]

  # TEARDOWN FLAG: this can't just be a simple "if networking is on, use
  # module.egress_vpc[0].x" check — Terraform checks BOTH sides of that
  # kind of statement even when only one will actually run, and it would
  # error trying to look at a VPC that doesn't exist. one() sidesteps
  # that: it just returns nothing (instead of erroring) when the VPC
  # doesn't exist, and coalesce() turns that "nothing" into an empty list
  # so the rest of this file always has something to work with.
  egress_public_route_table_ids = coalesce(one(module.egress_vpc[*].public_route_table_ids), [])

  # One route per (public route table x spoke CIDR). The keys are built
  # from the route table's position in the list plus the CIDR — both
  # known before anything is actually created. Using the route table's
  # real ID as the key instead would fail, since that ID doesn't exist
  # yet at this point. When networking is off, this naturally comes out
  # empty, so nothing extra needs to check for that here.
  public_spoke_routes = {
    for pair in setproduct(
      range(length(local.egress_public_route_table_ids)),
      local.spoke_cidrs
      ) : "${pair[0]}-${pair[1]}" => {
      route_table_id = local.egress_public_route_table_ids[pair[0]]
      cidr           = pair[1]
    }
  }
}

# -----------------------------------------------------------------------
# GitHub OIDC deploy role for this account
# -----------------------------------------------------------------------
# This boundary is used by the github-oidc-roles module below, which creates
# the actual deploy role in this account. That role is then assumed by
# the GitHub OIDC workflow in this account, which can then deploy the
# egress VPC, TGW, and spoke-wiring roles. The spoke accounts have
# their own github-oidc-roles modules, which create their own deploy roles
module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "network"
  management_account_id = var.management_account_id
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "network" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  enable_vpc_networking = true
  enable_ram_sharing    = true

  # This is a list of the role names that will be created by modules/tgw-spoke-wiring-role, which the deploy role needs to be able to assume.
  manage_named_roles = [
    "TgwSpokeWiringProduction",
    "TgwSpokeWiringDevelopment",
  ]
}

# This module creates the actual deploy role in this account, which is assumed by the GitHub OIDC workflow. 
# It uses the permissions boundary created above to limit what the deploy role can do.
module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "network"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = var.management_account_id
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "network" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}

# -----------------------------------------------------------------------
# Egress VPC (10.10.0.0/16)
#   private_subnets = TGW attachment subnets (sub-tgw-egress-a/b)
#   public_subnets  = NAT gateway subnets    (sub-nat-egress-a/b)
# The registry vpc module gives us exactly the route tables the design
# doc calls for: private -> local + 0.0.0.0/0 via NAT (AZ-local),
# public -> local + 0.0.0.0/0 via IGW.
# -----------------------------------------------------------------------
# This whole module is gated by var.networking_enabled, so it doesn't even try to create a VPC when networking is off. 
# That makes all the references to module.egress_vpc[0] below safe: they only run when the VPC actually exists.
module "egress_vpc" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/vpc"

  # This VPC and module.github-oidc-roles (which sets up this account's
  # own CI permissions) can sometimes run at the same time and collide —
  # AWS doesn't make a permission change visible everywhere instantly.
  # If that happens, the fix is a retry step in
  # .github/workflows/terraform-apply.yaml, not something added here.
  name = "egress-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # This account's egress VPC is the only one that needs NAT gateways, so the module's default of "one per AZ" is fine. 
  # The design doc's subnet table already has the public subnets in the right AZ order for that.
  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  single_nat_gateway     = false

  # Subnet/IGW names match var.azs order; see the design doc's subnet table.
  private_subnet_names = ["private-sub-tgw-a", "private-sub-tgw-b"]
  public_subnet_names  = ["public-sub-nat-egress-a", "public-sub-nat-egress-b"]
  igw_tags             = { Name = "igw-egress" }

  tags = var.tags
}

# -----------------------------------------------------------------------
# Exact per-AZ naming for NAT gateways and private (TGW) route tables.
# modules/vpc only takes one flat tags map for these, which would give
# both AZs the same name — aws_ec2_tag overwrites the Name tag per AZ
# after the fact instead. Public route table doesn't need this (only one,
# shared) but tagged the same way for consistency.
# -----------------------------------------------------------------------
locals {
  # "eu-west-2a" -> "a", "eu-west-2b" -> "b", matching the design doc's
  # naming convention. var.azs order must match private_subnets/
  # public_subnets order, which modules/vpc already requires.
  az_suffixes = [for az in var.azs : substr(az, -1, 1)]

  # TEARDOWN FLAG: built from var.azs only (no module reference), so a
  # plain ternary is safe. Resolving to {} when disabled gives the two
  # aws_ec2_tag resources below zero instances, making their
  # module.egress_vpc[0] references safe.
  nat_gateway_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "nat-egress-${suffix}"
  } : {}

  private_tgw_route_table_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "private-tgw-egress-rtb-${suffix}"
  } : {}
}
# This resource block creates Name tags for each NAT gateway in the egress VPC, using the names defined in local.nat_gateway_names.
# It uses a for_each loop to iterate over the local.nat_gateway_names map, creating a tag for each NAT gateway.
resource "aws_ec2_tag" "nat_gateway_name" {
  for_each = local.nat_gateway_names

  # This resource_id is set to the corresponding NAT gateway ID from module.egress_vpc[0].natgw_ids
  # and the key is set to "Name" with the value being the name from local.nat_gateway_names.
  resource_id = module.egress_vpc[0].natgw_ids[each.key]
  key         = "Name"
  value       = each.value
}

# This resource block creates private route table Name tags for each private route table in the egress VPC, 
# using the names defined in local.private_tgw_route_table_names. 
resource "aws_ec2_tag" "private_tgw_route_table_name" {
  for_each = local.private_tgw_route_table_names

  resource_id = module.egress_vpc[0].private_route_table_ids[each.key]
  key         = "Name"
  value       = each.value
}

# This resource block creates public route table Name tag for the shared public route table in the egress VPC.
resource "aws_ec2_tag" "public_nat_route_table_name" {
  count = var.networking_enabled ? 1 : 0

  # This resource_id is set to the public route table ID from module.egress_vpc[0].public_route_table_ids, 
  # and the key is set to "Name" with the value being "public-nat-egress-rtb".
  resource_id = module.egress_vpc[0].public_route_table_ids[0]
  key         = "Name"
  value       = "public-nat-egress-rtb"
}

# -----------------------------------------------------------------------
# This resource block creates routes in the public route tables of the egress VPC 
# to send traffic destined for spoke CIDRs back into the Transit Gateway (TGW).
# -----------------------------------------------------------------------
resource "aws_route" "public_to_spokes" {
  for_each = local.public_spoke_routes

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr
  # Safe to reference module.tgw[0] here: this whole resource is empty
  # whenever egress_vpc (and so tgw, gated the same way) doesn't exist,
  # so it never actually tries to look at a TGW that isn't there.
  transit_gateway_id = module.tgw[0].tgw_id

  # The TGW attachment must exist before a route can target the TGW.
  depends_on = [module.egress_tgw_attachment]
}

# -----------------------------------------------------------------------
# This module creates the Transit Gateway (TGW) in the network account, with the specified name and Amazon side ASN.
# It also shares the TGW with the specified principals (production and development account IDs) using AWS Resource Access Manager (RAM).
# The count parameter is used to conditionally create the TGW only when networking is enabled.
# -----------------------------------------------------------------------
module "tgw" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw"

  name            = "core-tgw"
  amazon_side_asn = var.amazon_side_asn

  # These are just account IDs, not secrets — but Terraform's SSM data
  # source always marks .value as sensitive no matter what it actually
  # holds, and a for_each loop won't accept a sensitive value directly.
  # nonsensitive() tells Terraform "trust me, this one's fine to show".
  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.production_account_id.value),
    nonsensitive(data.aws_ssm_parameter.development_account_id.value),
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# This module creates a Transit Gateway attachment for the egress VPC, connecting it to the Transit Gateway (TGW).
# This attachment allows the egress VPC to communicate with the TGW and route traffic to and from the spoke accounts.
# This module also applies the specified tags to the attachment for identification and management purposes.
# This module is essential for enabling communication between the egress VPC and the TGW, allowing traffic to flow between the egress VPC and the spoke accounts.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
module "egress_tgw_attachment" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-attachment"

  name       = "tgw-attach-Egress-vpc"
  tgw_id     = module.tgw[0].tgw_id
  vpc_id     = module.egress_vpc[0].vpc_id
  subnet_ids = module.egress_vpc[0].private_subnet_ids

  tags = var.tags
}

# -------------------------------------------------------------------------------------------------------------------------------------
# This resource block associates the egress VPC's Transit Gateway attachment with the main route table of the Transit Gateway (TGW).
# This association allows traffic from the egress VPC to be routed through the TGW and reach the spoke accounts.
# The count parameter is used to conditionally create the association only when networking is enabled.
# -------------------------------------------------------------------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  count = var.networking_enabled ? 1 : 0

  transit_gateway_attachment_id  = module.egress_tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = module.tgw[0].tgw_route_table_ids["main"]
}

# -----------------------------------------------------------------------
# Each spoke's table gets a catch-all route to the egress attachment,
# plus a "blackhole" (drop the traffic, don't route it anywhere) for the
# OTHER spoke's address range. That blackhole is what actually keeps
# prod and dev apart: without it, traffic meant for the other spoke would
# just ride the catch-all route out through NAT and come right back in
# via aws_route.public_to_spokes. Routers always prefer the more specific
# match, so the blackhole wins over the catch-all every time.
#
# TEARDOWN FLAG: needs module.tgw and egress_tgw_attachment, both of
# which turn off during a teardown, so these have to as well.
# -----------------------------------------------------------------------

# This module creates static routes in the production spoke's route table of the Transit Gateway (TGW) 
# this allows the production spoke to route traffic through the TGW and reach the egress VPC. 
# The blackhole_cidrs parameter is used to specify the CIDRs that should be blackholed (dropped) in the production spoke's route table, preventing traffic from being routed to the development spoke.

module "routes_prod_spoke" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw[0].tgw_route_table_ids["prod_spoke"]

  routes = {
    "0.0.0.0/0" = module.egress_tgw_attachment[0].attachment_id
  }

  blackhole_cidrs = [var.dev_cidr]
}

# This module creates static routes in the development spoke's route table of the Transit Gateway (TGW)
# this allows the development spoke to route traffic through the TGW and reach the egress VPC. 
# The blackhole_cidrs parameter is used to specify the CIDRs that should be blackholed (dropped) in the development spoke's route table,
# This preventing traffic from being routed to the production spoke.
module "routes_dev_spoke" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw[0].tgw_route_table_ids["dev_spoke"]

  routes = {
    "0.0.0.0/0" = module.egress_tgw_attachment[0].attachment_id
  }

  blackhole_cidrs = [var.prod_cidr]
}

# -----------------------------------------------------------------------
# This publishes what a spoke account (production or development) needs
# to know to connect itself to the TGW, and gives each one a role that
# can only touch its own route table plus "main" — nothing else. Each
# spoke does its own wiring directly (see the aws.network provider alias
# in production/development main.tf), rather than us reading their state.
#
# TEARDOWN FLAG: the SSM parameters below are never turned off, even
# though they'd normally get their value from module.tgw, which IS
# turned off during a teardown. A parameter can't just go blank when
# that happens — it needs SOME value. So each one also has a matching
# "_frozen" data source that, right before module.tgw is destroyed,
# reads back whatever value is currently sitting in AWS and keeps using
# that instead. Whichever one actually exists at the time (the live
# value or the frozen one) is what gets used.
# -----------------------------------------------------------------------
data "aws_ssm_parameter" "tgw_id_frozen" {
  count = var.networking_enabled ? 0 : 1
  name  = "/transit-gateway/id"
}

data "aws_ssm_parameter" "ram_resource_share_arn_frozen" {
  count = var.networking_enabled ? 0 : 1
  name  = "/transit-gateway/ram_resource_share_arn"
}

data "aws_ssm_parameter" "tgw_route_table_id_main_frozen" {
  count = var.networking_enabled ? 0 : 1
  name  = "/transit-gateway/route_table_ids/main"
}

data "aws_ssm_parameter" "tgw_route_table_id_prod_spoke_frozen" {
  count = var.networking_enabled ? 0 : 1
  name  = "/transit-gateway/route_table_ids/prod_spoke"
}

data "aws_ssm_parameter" "tgw_route_table_id_dev_spoke_frozen" {
  count = var.networking_enabled ? 0 : 1
  name  = "/transit-gateway/route_table_ids/dev_spoke"
}

resource "aws_ssm_parameter" "tgw_id" {
  name  = "/transit-gateway/id"
  type  = "String"
  value = coalesce(one(module.tgw[*].tgw_id), one(data.aws_ssm_parameter.tgw_id_frozen[*].value))
  tags  = var.tags
}

resource "aws_ssm_parameter" "ram_resource_share_arn" {
  name  = "/transit-gateway/ram_resource_share_arn"
  type  = "String"
  value = coalesce(one(module.tgw[*].ram_resource_share_arn), one(data.aws_ssm_parameter.ram_resource_share_arn_frozen[*].value))
  tags  = var.tags
}

resource "aws_ssm_parameter" "tgw_route_table_id_main" {
  name  = "/transit-gateway/route_table_ids/main"
  type  = "String"
  value = coalesce(try(one(module.tgw[*].tgw_route_table_ids)["main"], null), one(data.aws_ssm_parameter.tgw_route_table_id_main_frozen[*].value))
  tags  = var.tags
}

resource "aws_ssm_parameter" "tgw_route_table_id_prod_spoke" {
  name  = "/transit-gateway/route_table_ids/prod_spoke"
  type  = "String"
  value = coalesce(try(one(module.tgw[*].tgw_route_table_ids)["prod_spoke"], null), one(data.aws_ssm_parameter.tgw_route_table_id_prod_spoke_frozen[*].value))
  tags  = var.tags
}

resource "aws_ssm_parameter" "tgw_route_table_id_dev_spoke" {
  name  = "/transit-gateway/route_table_ids/dev_spoke"
  type  = "String"
  value = coalesce(try(one(module.tgw[*].tgw_route_table_ids)["dev_spoke"], null), one(data.aws_ssm_parameter.tgw_route_table_id_dev_spoke_frozen[*].value))
  tags  = var.tags
}

locals {
  tgw_ssm_parameter_arns = [
    aws_ssm_parameter.tgw_id.arn,
    aws_ssm_parameter.ram_resource_share_arn.arn,
    aws_ssm_parameter.tgw_route_table_id_main.arn,
  ]

  network_account_id = nonsensitive(data.aws_ssm_parameter.network_account_id.value)

  # TEARDOWN FLAG: the two role modules below never turn off, so their
  # inputs can't turn off either — built from the SSM parameters (always
  # present, frozen when disabled) rather than module.tgw directly, which
  # does turn off.
  main_route_table_arn = "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${aws_ssm_parameter.tgw_route_table_id_main.value}"
}


# this module creates a role in the production spoke account that allows it to wire itself into the Transit Gateway (TGW) in the network account.
# The role is granted permissions to modify the production spoke's route table and the main route table of the TGW, allowing it to create routes for traffic destined for the egress VPC.
# The ssm_parameter_arns parameter is used to specify the ARNs of the SSM parameters that the role needs access to, which include the TGW ID, RAM resource share ARN, and route table IDs.
# The tags parameter is used to apply tags to the role for identification and management purposes.
module "tgw_spoke_wiring_production" {
  source = "../../modules/tgw-spoke-wiring-role"

  name             = "TgwSpokeWiringProduction"
  spoke_account_id = nonsensitive(data.aws_ssm_parameter.production_account_id.value)

  route_table_arns = [
    "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${aws_ssm_parameter.tgw_route_table_id_prod_spoke.value}",
    local.main_route_table_arn,
  ]

  ssm_parameter_arns = concat(local.tgw_ssm_parameter_arns, [
    aws_ssm_parameter.tgw_route_table_id_prod_spoke.arn,
  ])

  tags = var.tags
}

# This module creates a role in the development spoke account that allows it to wire itself into the Transit Gateway (TGW) in the network account.
# The role is granted permissions to modify the development spoke's route table and the main route table of the TGW, allowing it to create routes for traffic destined for the egress VPC.
# The ssm_parameter_arns parameter is used to specify the ARNs of the SSM parameters that the role needs access to, which include the TGW ID, RAM resource share ARN, and route table IDs.
module "tgw_spoke_wiring_development" {
  source = "../../modules/tgw-spoke-wiring-role"

  name             = "TgwSpokeWiringDevelopment"
  spoke_account_id = nonsensitive(data.aws_ssm_parameter.development_account_id.value)

  route_table_arns = [
    "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${aws_ssm_parameter.tgw_route_table_id_dev_spoke.value}",
    local.main_route_table_arn,
  ]

  ssm_parameter_arns = concat(local.tgw_ssm_parameter_arns, [
    aws_ssm_parameter.tgw_route_table_id_dev_spoke.arn,
  ])

  tags = var.tags
}
