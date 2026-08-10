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

  private_subnet_names = var.private_subnet_names
  public_subnet_names  = var.public_subnet_names
  igw_tags             = var.igw_tags

  tags = var.tags

}

