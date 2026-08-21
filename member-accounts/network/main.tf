########################################################################################
# Account: Network
# Purpose: Centralised egress VPC + Transit Gateway + NAT for all spoke
# accounts, plus the shared "main" TGW route table both spokes propagate
# into for return traffic.
#
# This account never reads spoke state. It publishes tgw_id,
# ram_resource_share_arn, and its route table IDs to SSM, and grants each
# spoke account a narrowly-scoped role (modules/tgw-spoke-wiring-role) to
# wire its own TGW association/propagation/return-route directly. Apply
# order: this account once, then any spoke account, in any order, one
# apply each. See member-accounts/production|development/main.tf.
#######################################################################################

terraform {
  required_version = "~> 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
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
  # Spoke CIDRs that need a return path through the egress VPC.
  spoke_cidrs = [var.prod_cidr, var.dev_cidr]

  # TEARDOWN FLAG: locals have no count of their own, so a plain
  # `var.networking_enabled ? module.egress_vpc[0].x : ...` ternary isn't
  # safe here: Terraform validates both branches regardless of which one
  # wins, and errors on module.egress_vpc[0] once egress_vpc's count is 0.
  # one() over the splat is the safe form: it returns null (never errors)
  # on zero instances, and coalesce() turns that null into a real empty
  # list so length()/indexing below always has something to operate on.
  egress_public_route_table_ids = coalesce(one(module.egress_vpc[*].public_route_table_ids), [])

  # One route per (public route table x spoke CIDR). for_each keys must
  # be known at plan time, so these are built from the route table INDEX
  # and the CIDR string (both static config), with the route table ID
  # itself kept in the value where apply-time values are allowed. Keying
  # directly off public_route_table_ids would error with "cannot be
  # determined until apply".
  #
  # Resolves to {} when networking is disabled: egress_public_route_table_ids
  # is [] then, so range(length([])) is empty and setproduct() has nothing
  # to multiply, so no explicit var.networking_enabled check is needed here.
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

# module.github-oidc-roles manages this same account's own TerraformDeploy
# role permissions (data.aws_iam_policy_document.permissions in that module).
# When a permissions change and a resource that needs it (e.g. the flow-log
# KMS key below) land in the same apply, Terraform has no dependency edge
# between them and applies both in parallel — the IAM policy update reports
# "Modifications complete" in under a second, but IAM's authorization layer
# is eventually consistent and can lag a few seconds behind that. Hit for
# real: a KMS CreateKey call failed with AccessDeniedException moments after
# the exact permission it needed had already been added, in the same apply.
# This makes every module below explicitly wait past that propagation
# window rather than relying on timing.
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

# -----------------------------------------------------------------------
# Egress VPC (10.10.0.0/16)
#   private_subnets = TGW attachment subnets (sub-tgw-egress-a/b)
#   public_subnets  = NAT gateway subnets    (sub-nat-egress-a/b)
# The registry vpc module gives us exactly the route tables the design
# doc calls for: private -> local + 0.0.0.0/0 via NAT (AZ-local),
# public -> local + 0.0.0.0/0 via IGW.
# -----------------------------------------------------------------------
module "egress_vpc" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/vpc"

  # See time_sleep.wait_for_deploy_role_permissions above.
  #
  # A direct depends_on on module.github-oidc-roles was tried here too, on
  # the theory that time_sleep's own "already recreated once" escape hatch
  # was letting a real pending policy update get skipped. It wasn't: the
  # apply that included it failed the exact same way, with no policy-update
  # line, before ever proving the extra edge did anything. The actual
  # failure (a stuck production teardown, resolved separately) turned out
  # to be unrelated to this dependency at all — depends_on can't reorder
  # the destroy of a resource whose parent module instance is being
  # entirely removed from configuration (count 1 -> 0), regardless of what
  # it points at. Kept to just time_sleep, which IS the confirmed-working
  # piece: see its triggers block for why the wait re-fires on every
  # permissions change, not just the first.
  depends_on = [time_sleep.wait_for_deploy_role_permissions]

  name = "egress-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # This account's NAT/egress VPC: the one case where enable_nat_gateway
  # = true and tgw_id is left null (it's the egress point itself, so it
  # doesn't need the module's own route-to-TGW).
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
# modules/vpc can't do this through a variable: the upstream module only
# takes one flat tags map for these (nat_gateway_tags,
# private_route_table_tags), which would give both AZs the same name
# instead of "nat-egress-a" vs "nat-egress-b". aws_ec2_tag overwrites the
# Name tag on the existing resource after the fact, one per AZ.
#
# The public route table doesn't need this (only one, shared by both NAT
# subnets, so a flat tag is already unambiguous) but is done the same way
# for consistency.
# -----------------------------------------------------------------------
locals {
  # "eu-west-2a" -> "a", "eu-west-2b" -> "b", matching the design doc's
  # naming convention. var.azs order must match private_subnets/
  # public_subnets order, which modules/vpc already requires.
  az_suffixes = [for az in var.azs : substr(az, -1, 1)]

  # TEARDOWN FLAG: both key sets are built purely from var.azs (static
  # config, no module reference), so gating with a plain ternary is safe.
  # Resolving to {} here is what gives the two aws_ec2_tag resources below
  # zero instances when disabled, which is what makes indexing
  # module.egress_vpc[0] inside their bodies safe.
  nat_gateway_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "nat-egress-${suffix}"
  } : {}

  private_tgw_route_table_names = var.networking_enabled ? {
    for idx, suffix in local.az_suffixes : idx => "private-tgw-egress-rtb-${suffix}"
  } : {}
}

resource "aws_ec2_tag" "nat_gateway_name" {
  for_each = local.nat_gateway_names

  # Safe: zero instances whenever networking is disabled (nat_gateway_names
  # is {} then), so module.egress_vpc[0] is never evaluated for a
  # nonexistent instance.
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

  # Single shared table, so index [0] is safe (module.vpc guarantees at
  # least one whenever public_subnets is non-empty, which it is here).
  # The outer [0] on egress_vpc is safe because this resource is itself
  # gated on the same condition, immediately above.
  resource_id = module.egress_vpc[0].public_route_table_ids[0]
  key         = "Name"
  value       = "public-nat-egress-rtb"
}

# -----------------------------------------------------------------------
# Return path, VPC side.
#
# The registry vpc module gives the public route tables "local" plus
# 0.0.0.0/0 -> IGW and nothing else. When a NAT gateway translates a
# reply back to a spoke address (10.20.x.x / 10.30.x.x) it consults the
# route table of the public subnet it lives in, finds no match, and the
# packet is dropped. Outbound works; return traffic silently disappears
# ("curl hangs", not a routing error).
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
  # egress_vpc, and therefore tgw (same condition), has zero instances,
  # so this resource has zero instances too and module.tgw[0] is never
  # evaluated for a nonexistent instance.
  transit_gateway_id = module.tgw[0].tgw_id

  # The TGW attachment must exist before a route can target the TGW.
  depends_on = [module.egress_tgw_attachment]
}

# -----------------------------------------------------------------------
# Transit Gateway (hub): creates "main" (egress's table, the one narrow
# surface both spokes share write access to for their return route) plus
# prod_spoke/dev_spoke (each isolated to its own spoke's automation
# only), and shares the TGW to prod/dev via RAM.
# -----------------------------------------------------------------------
module "tgw" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw"

  name            = "core-tgw"
  amazon_side_asn = var.amazon_side_asn

  # Account IDs, not secrets, but the SSM parameter data source marks
  # .value sensitive unconditionally, which for_each disallows.
  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.production_account_id.value),
    nonsensitive(data.aws_ssm_parameter.development_account_id.value),
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------
# TGW attachment for the egress VPC itself (this account owns the TGW, so
# no RAM acceptance step is needed). Associated with the "main" route
# table, consulted for everything entering the TGW from the egress VPC,
# i.e. all NAT return traffic. Both spokes propagate their own attachment
# into "main" (see member-accounts/production|development/main.tf), so
# return traffic already has a route to whichever spoke it's headed back
# to, without prod_spoke or dev_spoke ever being shared between them.
#
# TEARDOWN FLAG: not in the original gating list, added deliberately.
# This attachment is itself billable (~$0.05/hr) and its inputs reference
# both module.tgw and module.egress_vpc, both gated above; leaving it
# ungated would either keep paying for it directly or break the plan the
# moment either of those goes to zero instances. Same reasoning applies
# to the association resource right after it.
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

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  count = var.networking_enabled ? 1 : 0

  transit_gateway_attachment_id  = module.egress_tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = module.tgw[0].tgw_route_table_ids["main"]
}

# -----------------------------------------------------------------------
# Default route out of each spoke's own isolated table straight to the
# egress attachment, plus an explicit blackhole for the OTHER spoke's
# CIDR. The blackhole is what actually enforces isolation: without it,
# 10.30.0.0/16-bound traffic from prod falls through to the 0.0.0.0/0
# default, reaches the egress VPC, gets NAT'd, and the return-path route
# (aws_route.public_to_spokes) delivers it straight to dev. Longest-prefix
# match means the blackhole (an exact /16) always wins over the broader
# default, so that traffic is dropped at the TGW instead.
#
# TEARDOWN FLAG: not in the original gating list, added deliberately.
# Both reference module.tgw's route tables and module.egress_tgw_attachment
# (both gated above); the route tables they'd write into don't exist at
# all when disabled, so these must be gated too or the plan fails on a
# reference into an empty module.
# -----------------------------------------------------------------------
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
# Spoke-owned TGW wiring: publishes what a spoke needs to wire itself in,
# and grants each spoke a narrowly-scoped role to do that wiring directly
# against this account's TGW route tables (see aws.network provider alias
# in member-accounts/production|development/main.tf). Replaces the old
# terraform_remote_state approach, which made this account's plan depend
# on spoke state that itself depended on this account's outputs, a cycle
# that only "worked" via try()/count silently producing zero resources
# when a spoke hadn't been applied yet.
#
# Each role is scoped to its own spoke table plus "main" only, never the
# other spoke's table, and on "main" can only propagate its own return
# route, not associate/disassociate/manage the other spoke's presence.
#
# TEARDOWN FLAG: the 5 SSM parameters below stay ungated (spokes read
# them regardless of their own flag), but their value normally comes from
# module.tgw, which IS gated. A plain ternary can't null the value out
# when disabled (aws_ssm_parameter requires a non-null string, and a
# resource can't reference its own prior value).
#
# Fix: a "_frozen" data source per parameter, gated to the opposite
# condition, that reads back whatever the parameter currently holds in
# AWS. Data sources read before resource changes apply, so on the run
# that disables this account it captures the value just before module.tgw
# is destroyed, freezing it instead of erroring. On first-ever apply the
# frozen source has zero instances, so there's no chicken-and-egg problem.
#
# coalesce(one(module.tgw[*].x), one(data...frozen[*].value)) picks
# whichever side has an instance; one() never errors on zero instances.
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

  # TEARDOWN FLAG: module.tgw_spoke_wiring_production/development below
  # are deliberately never gated (see the comment on those modules).
  # Gating them would try to destroy aws_iam_role.this inside
  # modules/tgw-spoke-wiring-role, which has prevent_destroy = true, and
  # the whole apply would hard-fail. Since those modules always exist,
  # their inputs must always resolve too, so route table ARNs are built
  # from the SSM parameter resources' own values (always present, frozen
  # per above when disabled) rather than from module.tgw directly. No
  # one()/try() gymnastics needed here: aws_ssm_parameter.*.value is a
  # plain always-present resource attribute.
  main_route_table_arn = "arn:aws:ec2:${var.aws_region}:${local.network_account_id}:transit-gateway-route-table/${aws_ssm_parameter.tgw_route_table_id_main.value}"
}

# TEARDOWN FLAG: intentionally not gated. See local.main_route_table_arn
# above for why: gating this would attempt to destroy a prevent_destroy
# protected IAM role. The role (and its trust policy, i.e. who can assume
# it) survives networking_enabled = false; only its permissions policy
# ends up pointing at route tables that no longer exist, which is inert
# (AWS doesn't validate that a policy's Resource ARNs currently exist)
# rather than broken.
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

# TEARDOWN FLAG: intentionally not gated, same reasoning as
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
