# ======================================================================================
# Shared VPC module.
#
# Used by all three accounts:
#   - network      : egress VPC with NAT gateways (enable_nat_gateway = true, tgw_id = null)
#   - development  : private-only spoke, egress via TGW (enable_nat_gateway = false, tgw_id set)
#   - production   : private-only spoke, egress via TGW (enable_nat_gateway = false, tgw_id set)
# ======================================================================================

terraform {
  # >= 1.9 is REQUIRED, not cosmetic. The validation blocks in variables.tf reference
  # other variables (cross-object validation), which was introduced in Terraform 1.9.
  # On older versions those blocks fail with "Invalid reference in variable validation".
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Deliberately permissive for now because the accounts are currently split:
      # development is pinned to 5.100.0 and network to 6.55.0 in their lock files.
      # Once all three are aligned on one major, tighten this to e.g. "~> 6.0"
      # so the module stops silently accepting whatever the caller happens to have.
      version = ">= 5.0"
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # Only the network account VPC should set these to true.
  # Spoke VPCs stay private-only and route egress (outbound traffic) via the TGW instead.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # Spokes generally have no public subnets / IGW at all — enable_nat_gateway
  # false + an empty public_subnets list gives you a fully private VPC.

  tags = var.tags

}

# ======================================================================================
# Extra "spoke egress (outbound)" route added to every private route table, pointing
# 0.0.0.0/0 at the Transit Gateway.
#
# Only used when var.tgw_id is set — leave null for the network account's NAT VPC,
# which doesn't need this since it *is* the egress point.
#
# This ensures all outbound traffic from private subnets in spoke VPCs goes through
# the TGW to reach the network account's VPC for internet egress.
#
# NOTE ON for_each: the keys come from var.azs (known at plan time), NOT from
# module.vpc.private_route_table_ids (only known after apply). Terraform uses
# for_each keys as resource addresses, so they must be known before anything is
# created. The route table ID is looked up in the resource body, where
# apply-time values are allowed. Keying off the route table IDs directly produces:
#   Error: Invalid for_each argument ... values derived from resource attributes
#   that cannot be determined until apply
# ======================================================================================
resource "aws_route" "private_to_tgw" {
  for_each = var.tgw_id != null ? { for idx, az in var.azs : az => idx } : {}

  route_table_id         = module.vpc.private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id

  lifecycle {
    # Guards the index lookup above. The upstream module derives its private route
    # table count from the NAT gateway configuration, which does not always equal
    # length(var.azs) — e.g. single_nat_gateway = true collapses it to one table.
    # Without this, a mismatch surfaces as a bare "index out of range".
    #
    # This check lives here rather than in variables.tf because it references a
    # module output, which variable validation blocks cannot see.
    precondition {
      condition     = length(module.vpc.private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc.private_route_table_ids)} tables for ${length(var.azs)} AZs. Check that single_nat_gateway is false on spoke VPCs."
    }
  }
}
