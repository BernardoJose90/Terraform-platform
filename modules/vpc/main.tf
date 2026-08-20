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
  required_version = "~> 1.11.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # All three accounts are now aligned on provider 6.x (see their own
      # required_providers blocks), so this is pinned to match rather than
      # silently accepting whatever major the caller happens to have.
      version = "~> 6.0"
    }
  }
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  # 6.0.0 requires AWS provider v6 (already true for all three callers) and
  # switches the flow-log group ARN to build from data.aws_region.current[0].region
  # instead of the now-deprecated .name attribute; this is what silences the
  # "Deprecated attribute" plan warning coming out of vpc-flow-logs.tf.
  version = "~> 6.0"

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

  # Spokes generally have no public subnets/IGW at all: enable_nat_gateway
  # false + an empty public_subnets list gives you a fully private VPC.

  private_subnet_names = var.private_subnet_names
  public_subnet_names  = var.public_subnet_names
  igw_tags             = var.igw_tags

  # VPC Flow Logs -> CloudWatch Logs. On by default (var.enable_flow_log) so every
  # account using this module gets flow logs without having to ask for them; the
  # upstream module creates both the log group and the IAM role that writes to it.
  enable_flow_log                                 = var.enable_flow_log
  create_flow_log_cloudwatch_log_group            = var.enable_flow_log
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_log
  flow_log_destination_type                       = "cloud-watch-logs"
  flow_log_traffic_type                           = var.flow_log_traffic_type
  flow_log_max_aggregation_interval               = var.flow_log_max_aggregation_interval
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_cloudwatch_log_group_retention_in_days

  tags = var.tags

}

