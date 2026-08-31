# ======================================================================================
# Shared VPC module, used by all three accounts:
#   - network      : egress VPC with NAT gateways (enable_nat_gateway = true, tgw_id = null)
#   - development  : private-only spoke, egress via TGW (enable_nat_gateway = false, tgw_id set)
#   - production   : private-only spoke, egress via TGW (enable_nat_gateway = false, tgw_id set)
# ======================================================================================

terraform {
  # 1.9+ isn't just a nice-to-have here — it's required. The validation
  # blocks in variables.tf check one variable's value against another
  # variable, and Terraform only gained the ability to do that in 1.9. On
  # an older version, those blocks fail outright with "Invalid reference in
  # variable validation".
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # All three accounts are on AWS provider 6.x now, so this is pinned
      # to match them, rather than quietly accepting whatever major
      # version the calling account happens to have.
      version = "~> 6.0"
    }
  }
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ======================================================================================
# KMS key that encrypts the VPC flow logs at rest. One key per VPC,
# created whenever flow logs are turned on (enable_flow_log). It's scoped
# to log groups under "/aws/vpc-flow-log/" rather than one exact log group
# name, because the log group's name ends in the VPC's own ID — and this
# key gets created before that VPC exists, so that ID isn't known yet.
# ======================================================================================
locals {
  # Has to match the upstream module's own default exactly — we never
  # override this value ourselves.
  flow_log_cloudwatch_log_group_name_prefix = "/aws/vpc-flow-log/"
}

data "aws_iam_policy_document" "flow_log_kms" {
  count = var.enable_flow_log ? 1 : 0

  # Every KMS key policy needs a statement like this. Without an explicit
  # grant back to the account root, this account's own IAM policies would
  # lose all control over the key — a key's policy is the only thing AWS
  # checks for a principal that isn't otherwise named in it.
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
    # "*" here doesn't mean "any key" — a key policy document only ever
    # describes grants on the one key it's attached to, so "*" just means
    # "this key". The real scoping happens in the condition below instead.
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
  # 6.0.0 needs AWS provider v6, which all three accounts already have.
  # It also switches how the flow-log group's ARN gets built, away from an
  # attribute that AWS has since deprecated — which is what stops the
  # "Deprecated attribute" plan warning that vpc-flow-logs.tf used to show.
  version = "~> 6.0"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # Only the network account's VPC should ever set these to true — spoke
  # VPCs (production, development) stay private-only and send their
  # outbound traffic out through the TGW instead.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # A spoke VPC usually has no public subnets or internet gateway at all —
  # enable_nat_gateway = false plus an empty public_subnets list is what
  # gives you a fully private VPC.

  private_subnet_names = var.private_subnet_names
  public_subnet_names  = var.public_subnet_names
  igw_tags             = var.igw_tags

  # Flow logs go to CloudWatch Logs and are on by default
  # (var.enable_flow_log). This whole chain — the KMS key, the log group,
  # the delivery role/policy, and the flow log itself — needs several IAM
  # permissions on TerraformDeploy that aren't obvious just from reading
  # this file. They all live in modules/github-oidc-roles/main.tf, under
  # FlowLogKmsKey, CloudWatchLogGroups, and PassFlowLogDeliveryRole — check
  # there first if a change here starts failing with AccessDenied.
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

