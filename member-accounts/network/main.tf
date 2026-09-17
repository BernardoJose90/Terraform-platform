########################################################################################
# Account: Network
# This account holds the "egress" Virtual Private Cloud (VPC), the
# Transit Gateway (TGW), and the Network Address Translation (NAT)
# gateways that every other account uses to reach the internet. It also
# owns the shared "main" TGW route table, which both spoke accounts
# (production and development) publish their return routes into.
#
# This account never reads the state of the spoke accounts. Instead, it
# publishes IDs (tgw_id, ram_resource_share_arn, and route table IDs) to
# AWS Systems Manager (SSM) Parameter Store, and gives each spoke a
# narrow IAM role (see modules/tgw-spoke-wiring-role) that lets that
# spoke wire itself into the TGW.
#
# Apply this account first. After that, the two spoke accounts can be
# applied in either order.
#######################################################################################

terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # The "null" provider is used by modules/tgw for a step that waits
    # until the Transit Gateway is ready (a null_resource running a
    # local-exec script). See the comment above that resource in
    # modules/tgw for why this waiting step is needed.
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
  # The address ranges (Classless Inter-Domain Routing, or CIDR, blocks)
  # of the two spoke VPCs. Traffic from these ranges needs a route back
  # through the egress VPC.
  spoke_cidrs = [var.prod_cidr, var.dev_cidr]

  # TEARDOWN FLAG: this is part of a pattern used throughout this file to
  # support turning networking off (see var.networking_enabled below). We
  # can't just write a simple "if networking is on, use
  # module.egress_vpc[0].x" check, because Terraform evaluates both sides
  # of that kind of expression even when only one side will actually run
  # — it would try to read a VPC that doesn't exist and fail. one() avoids
  # that: it returns "nothing" instead of erroring when the VPC doesn't
  # exist, and coalesce() turns that "nothing" into an empty list, so the
  # rest of this file always has something valid to work with.
  egress_public_route_table_ids = coalesce(one(module.egress_vpc[*].public_route_table_ids), [])

  # Builds one route per combination of (public route table, spoke CIDR).
  # The map keys are built from the route table's position in the list
  # plus the CIDR, both of which are known before anything is created. We
  # can't use the route table's real AWS ID as the key instead, because
  # that ID doesn't exist yet at this point in the plan. When networking
  # is turned off, this map naturally comes out empty, so nothing else
  # needs to special-case that.
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
# Sets up the deploy role that GitHub Actions uses (via OpenID Connect,
# or OIDC — a way for GitHub to get temporary AWS credentials without a
# stored secret), plus the permissions boundary that limits what that
# role is allowed to do.
#
# This account's deploy role is the one that creates the egress VPC, the
# TGW, and the spoke-wiring roles below. enable_ram_sharing is turned on
# only here, nowhere else — it lets modules/tgw share the TGW with the
# spoke accounts using AWS Resource Access Manager (RAM).
# -----------------------------------------------------------------------
module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "network"
  management_account_id = var.management_account_id
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "network" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  enable_vpc_networking = true
  enable_ram_sharing    = true

  # Lists the spoke-wiring roles (created below via
  # modules/tgw-spoke-wiring-role) by name, so the permissions boundary
  # only allows managing these exact roles (identified by their Amazon
  # Resource Names, or ARNs) and nothing else.
  manage_named_roles = [
    "TgwSpokeWiringProduction",
    "TgwSpokeWiringDevelopment",
  ]
}

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
# The egress VPC itself (address range 10.10.0.0/16):
#   private_subnets = subnets used only for the TGW attachment's network
#                      interfaces (sub-tgw-egress-a/b)
#   public_subnets  = subnets that hold the NAT gateways (sub-nat-egress-a/b)
#
# The shared "vpc" module (from the Terraform Registry) automatically
# creates the route tables our design calls for:
#   - private subnets: route within the VPC directly, and send all other
#     traffic (0.0.0.0/0) out through the NAT gateway in the same
#     Availability Zone (AZ — an isolated location within the AWS region)
#   - public subnets: route within the VPC directly, and send all other
#     traffic out through the Internet Gateway (IGW), which is what gives
#     a VPC a path to the public internet
# -----------------------------------------------------------------------
# This whole module only runs when var.networking_enabled is true, so no VPC is created at all when networking is turned off.
# That's what makes every module.egress_vpc[0] reference further down in this file safe — they only get evaluated when the VPC actually exists.
module "egress_vpc" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/vpc"

  # Creating this VPC and setting up module.github-oidc-roles (this
  # account's CI/CD permissions) can sometimes happen at the same time
  # and conflict, because AWS doesn't make permission changes visible
  # everywhere instantly. If that happens, the fix is to add a retry step
  # in .github/workflows/terraform-apply.yaml — not to change anything
  # here.
  name = "egress-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # This egress VPC is the only VPC in the whole setup that needs NAT gateways, so it's fine to use the module's default of one NAT gateway per Availability Zone (AZ).
  # The design document's subnet table already lists the public subnets in the matching AZ order needed for this.
  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  single_nat_gateway     = false

  # Subnet and Internet Gateway (IGW) names line up with the order of var.azs; see the design document's subnet table.
  private_subnet_names = ["private-sub-tgw-a", "private-sub-tgw-b"]
  public_subnet_names  = ["public-sub-nat-egress-a", "public-sub-nat-egress-b"]
  igw_tags             = { Name = "igw-egress" }

  tags = var.tags
}

# -----------------------------------------------------------------------
# Gives each Availability Zone's NAT gateway and private (TGW) route
# table its own distinct name. modules/vpc only accepts one flat set of
# tags for all of these, which would give every AZ the exact same name.
# Instead, the aws_ec2_tag resources below go back afterward and set a
# unique "Name" tag per AZ. The public route table doesn't need this
# (there's only one, shared by both AZs), but it's tagged the same way
# below just for consistency.
# -----------------------------------------------------------------------
locals {
  # Turns "eu-west-2a" into "a", "eu-west-2b" into "b", matching the
  # design document's naming convention. The order of var.azs must match
  # the order of private_subnets and public_subnets — modules/vpc already
  # requires this.
  az_suffixes = [for az in var.azs : substr(az, -1, 1)]

  # TEARDOWN FLAG: this is built only from var.azs, with no reference to
  # the egress_vpc module, so a plain true/false check (ternary) is safe
  # here — there's no risk of Terraform trying to read a VPC that doesn't
  # exist. When networking is disabled this resolves to an empty map,
  # which gives the two aws_ec2_tag resources below zero instances to
  # create, so their references to module.egress_vpc[0] are never
  # actually evaluated.
  nat_gateway_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "nat-egress-${suffix}"
  } : {}

  private_tgw_route_table_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "private-tgw-egress-rtb-${suffix}"
  } : {}
}
# Creates one "Name" tag per Availability Zone — something modules/vpc's single flat tags map can't do on its own.
resource "aws_ec2_tag" "nat_gateway_name" {
  for_each = local.nat_gateway_names

  resource_id = module.egress_vpc[0].natgw_ids[each.key]
  key         = "Name"
  value       = each.value
}

resource "aws_ec2_tag" "private_tgw_route_table_name" {
  for_each = local.private_tgw_route_table_names

  resource_id = module.egress_vpc[0].private_route_table_ids[each.key]
  key         = "Name"
  value       = each.value
}

# There's only one public route table, shared by both AZs. It's tagged here the same way as the others, just for consistency.
resource "aws_ec2_tag" "public_nat_route_table_name" {
  count = var.networking_enabled ? 1 : 0

  resource_id = module.egress_vpc[0].public_route_table_ids[0]
  key         = "Name"
  value       = "public-nat-egress-rtb"
}

# -----------------------------------------------------------------------
# The "return path": routes in the egress VPC's public route tables that
# send traffic addressed to a spoke account's CIDR range back into the
# TGW. Without these, replies to outbound traffic that went through NAT
# would have no way to find their way back to the spoke account that
# sent them.
# -----------------------------------------------------------------------
resource "aws_route" "public_to_spokes" {
  for_each = local.public_spoke_routes

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr
  # It's safe to reference module.tgw[0] here: this whole resource has no
  # instances whenever the egress VPC (and therefore the TGW, which is
  # gated the same way) doesn't exist, so this line never actually runs
  # when there's no TGW to look at.
  transit_gateway_id = module.tgw[0].tgw_id

  # The TGW attachment (the VPC's actual connection to the TGW) has to
  # exist before a route can point at the TGW.
  depends_on = [module.egress_tgw_attachment]
}

# -----------------------------------------------------------------------
# The Transit Gateway itself, plus sharing it with the two spoke accounts
# via AWS Resource Access Manager (RAM). Only created when
# var.networking_enabled is true (see the TEARDOWN FLAG notes above).
# -----------------------------------------------------------------------
module "tgw" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw"

  name            = "core-tgw"
  amazon_side_asn = var.amazon_side_asn

  # These values are just AWS account IDs, not secrets. But Terraform's
  # SSM data source always marks its .value as "sensitive" no matter what
  # it actually contains, and Terraform won't let a for_each loop use a
  # sensitive value directly. nonsensitive() tells Terraform "trust me,
  # it's fine to use this value here".
  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.production_account_id.value),
    nonsensitive(data.aws_ssm_parameter.development_account_id.value),
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------
# Connects (attaches) the egress VPC to the TGW. This is the "hub" side
# of the hub-and-spoke network design — the spoke accounts attach to the
# same TGW from their own side.
# -----------------------------------------------------------------------
module "egress_tgw_attachment" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-attachment"

  name       = "tgw-attach-Egress-vpc"
  tgw_id     = module.tgw[0].tgw_id
  vpc_id     = module.egress_vpc[0].vpc_id
  subnet_ids = module.egress_vpc[0].private_subnet_ids

  tags = var.tags
}

# Associates the egress VPC's TGW attachment with the "main" route table
# — the same route table that both spoke accounts publish (propagate)
# their return routes into.
resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  count = var.networking_enabled ? 1 : 0

  transit_gateway_attachment_id  = module.egress_tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = module.tgw[0].tgw_route_table_ids["main"]
}

# -----------------------------------------------------------------------
# Each spoke account's route table gets two things:
#   1. A catch-all route sending all other traffic out through the
#      egress attachment.
#   2. A "blackhole" route for the OTHER spoke's address range — meaning
#      traffic to that range is simply dropped rather than routed
#      anywhere.
#
# That blackhole route is what actually keeps production and development
# network traffic separated. Without it, traffic meant for the other
# spoke would just follow the catch-all route out through NAT and come
# right back in via the aws_route.public_to_spokes routes above. Routers
# always use the most specific matching route available, so the more
# specific blackhole route always wins over the general catch-all route.
#
# TEARDOWN FLAG: these depend on module.tgw and egress_tgw_attachment,
# both of which are turned off during a teardown, so these modules have
# to be turned off the same way.
# -----------------------------------------------------------------------

# Production's route table: catch-all route out via egress, with development's address range blackholed.
module "routes_prod_spoke" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw[0].tgw_route_table_ids["prod_spoke"]

  routes = {
    "0.0.0.0/0" = module.egress_tgw_attachment[0].attachment_id
  }

  blackhole_cidrs = [var.dev_cidr]
}

# Development's route table: catch-all route out via egress, with production's address range blackholed.
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
# Publishes everything a spoke account (production or development) needs
# to know in order to connect itself to the TGW, and gives each spoke an
# IAM role that can only touch its own route table plus "main" —
# nothing else. Each spoke wires itself in directly, using that role
# (see the aws.network provider alias in production/development's
# main.tf), so this account never needs to read the spoke accounts'
# Terraform state.
#
# TEARDOWN FLAG: the SSM parameters below are never turned off, even
# though during normal operation they get their value from module.tgw —
# which IS turned off during a teardown. An SSM parameter can't be left
# blank; it always needs some value. So each parameter also has a
# matching "_frozen" data source. Right before module.tgw is destroyed,
# that data source reads back whatever value is currently stored in AWS,
# and the parameter keeps using that frozen value instead. Whichever
# source actually has a value at the time — the live one from
# module.tgw, or the frozen one — is what gets used.
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

  # TEARDOWN FLAG: the two role modules below are never turned off, so
  # their inputs can't be allowed to go missing either. That's why this
  # is built from the SSM parameters above (which always have a value,
  # live or frozen) rather than reading module.tgw directly, since
  # module.tgw itself does get turned off during a teardown.
  main_route_table_arn = "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${aws_ssm_parameter.tgw_route_table_id_main.value}"
}


# The cross-account IAM role that the production account assumes (via
# its aws.network provider alias) to wire itself into the TGW. It's
# scoped down to only the prod_spoke and "main" route tables, and only
# the SSM parameters it needs to read. This role is never turned off,
# even during a teardown (TEARDOWN FLAG).
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

# Same idea as tgw_spoke_wiring_production above, but for the
# development account — scoped to the dev_spoke and "main" route tables.
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
