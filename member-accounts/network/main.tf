###############################################################################
# Account: Network
# Purpose: Centralised egress VPC + Transit Gateway + NAT for all spoke accounts,
# plus the shared "main" TGW route table that both spokes can propagate into for return traffic.
#
# This account never reads spoke state. It publishes tgw_id, ram_resource_share_arn, and its route table IDs to SSM, and grants each
# spoke account a narrowly-scoped role (modules/tgw-spoke-wiring-role) to
# wire its own TGW association/propagation/return-route directly. Apply
# order is: this account once, then any spoke account, in any order one
# apply each — see member-accounts/production|development/main.tf for the
# other half.
###############################################################################

terraform {
  required_version = "~> 1.11.0"
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

# ----------------------------------------------------------------------
# Providers
# ----------------------------------------------------------------------
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

  # TEARDOWN FLAG: locals have no count of their own, so a plain
  # `var.networking_enabled ? module.egress_vpc[0].x : ...` ternary is NOT
  # safe here — Terraform validates the index in BOTH branches regardless
  # of which one wins, and errors on module.egress_vpc[0] the moment
  # egress_vpc's own count is 0. one() over the splat is the safe form:
  # it returns null (never errors) when the module has zero instances,
  # and coalesce() turns that null into a real empty list so length()/
  # indexing below always has something valid to operate on.
  egress_public_route_table_ids = coalesce(one(module.egress_vpc[*].public_route_table_ids), [])

  # ← ADDED. One route per (public route table x spoke CIDR).
  #
  # for_each keys must be known at plan time. The keys below are built from the
  # route table INDEX and the CIDR string — both static config — while the route
  # table ID itself stays in the value, where apply-time values are allowed.
  # Keying directly off public_route_table_ids would produce:
  #   Error: Invalid for_each argument ... cannot be determined until apply
  #
  # Naturally resolves to {} when networking is disabled: egress_public_route_table_ids
  # is [] in that case, so range(length([])) is empty and setproduct(...) has
  # nothing to multiply — no explicit var.networking_enabled check needed here.
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
module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "network"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = var.management_account_id
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "network" # must match the backend "s3" key above
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
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/vpc"

  name = "egress-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # This is the network account's NAT/egress VPC  the one case where
  # enable_nat_gateway = true and tgw_id is left null (it *is* the
  # egress point, so it doesn't need the module's own route-to-TGW).
  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  single_nat_gateway     = false

  # Subnet/IGW names match var.azs order — see the design doc's subnet table.
  private_subnet_names = ["private-sub-tgw-a", "private-sub-tgw-b"]
  public_subnet_names  = ["public-sub-nat-egress-a", "public-sub-nat-egress-b"]
  igw_tags             = { Name = "igw-egress" }

  tags = var.tags
}

# -----------------------------------------------------------------------
# ← ADDED: exact per-AZ naming for NAT gateways and private (TGW) route
# tables. modules/vpc can't do this through a variable — the upstream
# module only takes one flat tags map for these (nat_gateway_tags,
# private_route_table_tags), which would apply the SAME name to both
# instead of "nat-egress-a" vs "nat-egress-b". aws_ec2_tag just overwrites
# the Name tag on the existing resource after the fact, one per AZ.
#
# The public route table doesn't need this — there's only one of it
# (single shared table for both NAT subnets), so a flat tag would already
# be unambiguous — but it's done the same way here for consistency.
# -----------------------------------------------------------------------
locals {
  # "eu-west-2a" -> "a", "eu-west-2b" -> "b" — matches the design doc's
  # naming convention. var.azs order must match private_subnets/
  # public_subnets order, which modules/vpc already requires.
  az_suffixes = [for az in var.azs : substr(az, -1, 1)]

  # TEARDOWN FLAG: these two key sets are built purely from var.azs (static
  # config, no module reference), so gating them with a plain ternary is
  # safe — there's nothing in either branch that could index into a
  # zero-instance module. Resolving to {} here is what makes the two
  # aws_ec2_tag resources below have zero instances when disabled, which
  # is in turn what makes indexing module.egress_vpc[0] INSIDE their
  # bodies safe (see the per-resource comments).
  nat_gateway_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "nat-egress-${suffix}"
  } : {}

  private_tgw_route_table_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "private-tgw-egress-rtb-${suffix}"
  } : {}
}

resource "aws_ec2_tag" "nat_gateway_name" {
  for_each = local.nat_gateway_names

  # Safe: this resource has zero instances whenever networking is
  # disabled (nat_gateway_names is {} in that case, see above), so
  # module.egress_vpc[0] is never evaluated for a nonexistent instance.
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

resource "aws_ec2_tag" "public_nat_route_table_name" {
  count = var.networking_enabled ? 1 : 0

  # Single shared table — index [0] is safe (module.vpc guarantees at
  # least one whenever public_subnets is non-empty, which it is here).
  # The outer [0] on egress_vpc is safe because this whole resource is
  # itself gated on the same condition, immediately above.
  resource_id = module.egress_vpc[0].public_route_table_ids[0]
  key         = "Name"
  value       = "public-nat-egress-rtb"
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
  # Safe: for_each is {} (see local.public_spoke_routes) whenever
  # egress_vpc — and therefore tgw, which shares the same condition —
  # has zero instances, so this resource has zero instances too and
  # module.tgw[0] is never evaluated for a nonexistent instance.
  transit_gateway_id = module.tgw[0].tgw_id

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
  count = var.networking_enabled ? 1 : 0

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
#
# TEARDOWN FLAG: not in the original gating list, added deliberately.
# This attachment is itself billable (~$0.05/hr) AND its inputs reference
# both module.tgw and module.egress_vpc, both gated above — leaving it
# ungated would either keep paying for it directly, or break the plan the
# moment either of those goes to zero instances. Same reasoning applies
# to the association resource right after it.
module "egress_tgw_attachment" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-attachment"

  name       = "tgw-attach-Egress-vpc"
  tgw_id     = module.tgw[0].tgw_id
  vpc_id     = module.egress_vpc[0].vpc_id
  subnet_ids = module.egress_vpc[0].private_subnet_ids

  tags = var.tags
}

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  count = var.networking_enabled ? 1 : 0

  transit_gateway_attachment_id  = module.egress_tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = module.tgw[0].tgw_route_table_ids["main"]
}

# -----------------------------------------------------------------------
# Default route out of each spoke's own isolated table, straight to the
# egress attachment — plus an explicit blackhole for the OTHER spoke's
# CIDR. The blackhole is what actually enforces isolation: without it,
# 10.30.0.0/16-bound traffic from prod has no specific route, falls
# through to the 0.0.0.0/0 default, reaches the egress VPC, gets NAT'd,
# and the return-path route (aws_route.public_to_spokes) delivers it
# straight to dev — prod and dev reaching each other despite neither
# table ever containing a route to the other. Longest-prefix-match means
# the blackhole (an exact /16 match) always wins over the broader default
# route, so that traffic is dropped at the TGW instead.
# -----------------------------------------------------------------------
# TEARDOWN FLAG: not in the original gating list, added deliberately.
# Both reference module.tgw's route tables and module.egress_tgw_attachment,
# both gated above — the route tables they'd write into don't exist at all
# when disabled, so these must be gated too or the plan fails on a
# reference into an empty module.
module "routes_prod_spoke" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw[0].tgw_route_table_ids["prod_spoke"]

  routes = {
    "0.0.0.0/0" = module.egress_tgw_attachment[0].attachment_id
  }

  blackhole_cidrs = [var.dev_cidr]
}

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
# -----------------------------------------------------------------------
# TEARDOWN FLAG — these 5 SSM parameters are deliberately left ungated, per
# instruction: a spoke's plan reads them regardless of that spoke's own
# flag, so they must never disappear. But their VALUE is normally computed
# from module.tgw, which DOES get gated above — and a plain
# `var.networking_enabled ? module.tgw[0].x : null` doesn't work: these
# resources are never gated themselves (always exist, config-time
# evaluated), aws_ssm_parameter's value argument is a required non-null
# string (can't just become null when disabled), and a resource can't
# reference its own prior value to "freeze" it.
#
# The fix: a matching "_frozen" data source per parameter, gated to the
# OPPOSITE condition (only reads when disabled), which reads back
# whatever this same parameter is CURRENTLY holding in AWS. Terraform
# reads data sources before applying resource changes in the same plan,
# so on the run that flips this account to disabled, it captures the
# value as it stood just before module.tgw is destroyed in that same
# apply — the parameter freezes at its last real value instead of
# erroring. On first-ever apply (networking_enabled defaults to true) the
# frozen data source has zero instances and is never queried, so there's
# no bootstrapping chicken-and-egg problem reading a parameter that
# doesn't exist yet.
#
# coalesce(one(module.tgw[*].x), one(data...frozen[*].value)) picks
# whichever side actually has an instance; one() never errors on zero
# instances on either side, so exactly one of the two always wins.
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

  # TEARDOWN FLAG: module.tgw_spoke_wiring_production/development below are
  # deliberately NEVER gated (see the comment on those modules) — gating
  # them would try to destroy aws_iam_role.this inside
  # modules/tgw-spoke-wiring-role, which has prevent_destroy = true, and
  # the whole apply would hard-fail. Since those modules always exist,
  # their inputs must always resolve too — so route table ARNs are built
  # from the SSM parameter resources' OWN values (always present, frozen
  # per above when disabled) rather than from module.tgw directly. This
  # also means no one()/try() gymnastics are needed here specifically:
  # aws_ssm_parameter.*.value is a plain always-present resource attribute.
  main_route_table_arn = "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${aws_ssm_parameter.tgw_route_table_id_main.value}"
}

# TEARDOWN FLAG: intentionally NOT gated. See local.main_route_table_arn
# above for why — gating this would attempt to destroy a prevent_destroy
# protected IAM role. The role (and its trust policy, i.e. WHO can assume
# it) survives networking_enabled = false; only its permissions policy
# below ends up pointing at route tables that no longer exist, which is
# inert (AWS doesn't validate that a policy's Resource ARNs currently
# exist) rather than broken.
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

# TEARDOWN FLAG: intentionally NOT gated — same reasoning as
# tgw_spoke_wiring_production above.
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
