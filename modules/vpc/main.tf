# ======================================================================================
# Shared VPC (Virtual Private Cloud) module. All three networking accounts
# use it:
#   - network     : the internet-facing VPC. It has NAT (Network Address
#                   Translation) gateways turned on (enable_nat_gateway =
#                   true) and no Transit Gateway id (tgw_id = null).
#   - development : a private-only "spoke" VPC (enable_nat_gateway =
#                   false). tgw_id is set once it's wired into the
#                   Transit Gateway (TGW), and left null while it's
#                   running detached/isolated.
#   - production  : a private-only spoke VPC (enable_nat_gateway = false,
#                   tgw_id set).
#
# A Transit Gateway is AWS's hub for routing traffic between VPCs and
# on-prem networks, instead of connecting every VPC to every other VPC
# directly.
#
# This module creates the VPC itself, its subnets, its route tables, and
# (optionally) flow logs. It deliberately does NOT create the default
# route (0.0.0.0/0, meaning "everything else") that sends outbound
# traffic to the Transit Gateway. That route is created in the calling
# account's own main.tf instead, because it can only be created after
# the VPC is attached to the TGW — and that attachment happens after this
# module has already run. tgw_id is still passed into this module, but
# only so the checks in variables.tf can confirm the caller has set up a
# consistent way for traffic to leave the VPC.
# ======================================================================================

terraform {
  # This version must match .terraform-version, which is the single
  # source of truth that CI reads. The minimum version matters here: the
  # validation blocks in variables.tf check one variable's value against
  # another, and Terraform has only supported that since version 1.9. On
  # an older CLI those checks fail outright with an "Invalid reference in
  # variable validation" error.
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # All three accounts now use version 6.x of the AWS provider (the
      # plugin Terraform uses to talk to AWS), so this is pinned to match
      # them. That's safer than silently accepting whatever major version
      # happens to be installed in the calling account.
      version = "~> 6.0"
    }
  }
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ======================================================================================
# KMS (Key Management Service) key used to encrypt the VPC's flow logs at
# rest. Flow logs are records of the network traffic going in and out of
# the VPC. One key is created per VPC, whenever flow logs are turned on
# (enable_flow_log). The key's policy scopes it to any log group whose
# name starts with "/aws/vpc-flow-log/", rather than to one exact log
# group name. That's because the real log group's name ends in the VPC's
# own ID, and this key has to be created before the VPC exists — so that
# ID isn't known yet.
# ======================================================================================
locals {
  # This value must exactly match the default used internally by the
  # upstream VPC module we call below — we never override it ourselves.
  flow_log_cloudwatch_log_group_name_prefix = "/aws/vpc-flow-log/"
}

data "aws_iam_policy_document" "flow_log_kms" {
  count = var.enable_flow_log ? 1 : 0

  # Every KMS key policy needs a statement like this one. It grants
  # access back to the AWS account's root user. Without it, this
  # account's own IAM (Identity and Access Management) policies would
  # have no control over the key at all: for any principal (user or role)
  # not explicitly named in the key's policy, AWS checks only that
  # policy, and ignores IAM policies entirely.
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
    # This "*" does not mean "any KMS key". A key's own policy document
    # can only ever grant permissions on the single key it's attached to,
    # so "*" here just means "this key". The actual narrowing of access
    # happens in the condition block below.
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
  # Version 6.x requires v6 of the AWS provider, which all three accounts
  # already use. It also builds the flow log group's ARN (Amazon Resource
  # Name, AWS's unique identifier format) from a newer attribute, which
  # is what got rid of an old "Deprecated attribute" warning during plan.
  version = "~> 6.0"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # Only the network account's VPC should ever set these to true. Spoke
  # VPCs (production, development) stay private-only, and send their
  # outbound traffic through the Transit Gateway instead.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # A spoke VPC usually has no public subnets or Internet Gateway (IGW,
  # the resource that lets a VPC reach the public internet directly) at
  # all. Setting enable_nat_gateway = false together with an empty
  # public_subnets list is what makes the VPC fully private.

  private_subnet_names = var.private_subnet_names
  public_subnet_names  = var.public_subnet_names
  igw_tags             = var.igw_tags

  # Flow logs are sent to CloudWatch Logs and are on by default
  # (var.enable_flow_log). This whole chain — the KMS key, the log group,
  # the IAM role/policy that delivers logs, and the flow log resource
  # itself — depends on several IAM permissions granted to the
  # TerraformDeploy role. Those permissions aren't visible from this file
  # alone; they live in modules/github-oidc-roles/main.tf, under the
  # FlowLogKmsKey, CloudWatchLogGroups, and PassFlowLogDeliveryRole
  # sections. Check there first if a change here starts failing with an
  # AccessDenied error.
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
