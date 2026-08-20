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

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ======================================================================================
# KMS key for VPC Flow Log encryption at rest. One CMK per VPC, only created when flow
# logs are (enable_flow_log), so it follows the same everyone-gets-it-by-default toggle.
#
# Scoped narrowly: CloudWatch Logs may only use this key to encrypt/decrypt log groups
# under the "/aws/vpc-flow-log/" prefix in this account and region — the prefix the
# upstream module always uses for flow-log groups (flow_log_cloudwatch_log_group_name_prefix,
# left at its default; see local.flow_log_cloudwatch_log_group_name_prefix below). It is not
# scoped to the exact log group name because that name's suffix defaults to the VPC id,
# which doesn't exist yet at plan time — this key is created before the VPC it protects.
# ======================================================================================
locals {
  # Must match the upstream module's flow_log_cloudwatch_log_group_name_prefix default —
  # we never override that variable, so this mirrors it rather than re-deriving it.
  flow_log_cloudwatch_log_group_name_prefix = "/aws/vpc-flow-log/"
}

data "aws_iam_policy_document" "flow_log_kms" {
  count = var.enable_flow_log ? 1 : 0

  # Required on every KMS key policy: without an explicit root grant, IAM
  # policies on this account's roles/users stop being able to control the key
  # at all, since the key's own policy is the only thing consulted for a
  # principal who isn't named elsewhere in it.
  statement {
    sid     = "EnableIAMUserPermissions"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    # KMS key policies always use resources = ["*"] here — "*" means "this key",
    # since a key policy document only ever describes grants on itself. The
    # actual scoping is the condition below, not this line.
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.flow_log_cloudwatch_log_group_name_prefix}*"]
    }
  }
}

resource "aws_kms_key" "flow_log" {
  count = var.enable_flow_log ? 1 : 0

  description             = "CMK for ${var.name} VPC flow log CloudWatch log group"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.flow_log_kms[0].json

  tags = var.tags
}

resource "aws_kms_alias" "flow_log" {
  count = var.enable_flow_log ? 1 : 0

  name          = "alias/${var.name}-vpc-flow-log"
  target_key_id = aws_kms_key.flow_log[0].key_id
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
  flow_log_cloudwatch_log_group_kms_key_id        = var.enable_flow_log ? aws_kms_key.flow_log[0].arn : null

  tags = var.tags

}

