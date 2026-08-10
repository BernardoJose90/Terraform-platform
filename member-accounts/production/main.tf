###############################################################################
# Account: Production
# Email  : james.jose109099+aws-prod@gmail.com
# Purpose: Live workload hosting
###############################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "production/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# Provider for reading SSM from management account (for account ID only)
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

# Read the production account ID from SSM (management account)
data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# Read the network account ID from SSM (management account) — needed to
# construct the TGW spoke-wiring role ARN below.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# Main provider for the production account itself
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]
}

# Assumes a role in the network account that's scoped to prod_spoke +
# main only (modules/tgw-spoke-wiring-role) — this account can never
# touch tgw-dev-spoke-rt. Replaces terraform_remote_state, which read
# the network account's entire state file and, worse, made network's own
# plan depend on this account's output — a cycle neither account could
# apply cleanly on its own. See member-accounts/network/main.tf for the
# other half.
provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction"
  }
}

# Published by the network account. Read via the aws.network role instead
# of terraform_remote_state, so this account's plan role never needs S3
# read access to the network account's full state file.
data "aws_ssm_parameter" "tgw_id" {
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "prod_spoke_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/prod_spoke"
}

# The "main" table is the one narrow surface this account shares write
# access to with development — used only to propagate this VPC's own
# return route, never to touch dev_spoke.
data "aws_ssm_parameter" "main_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "production"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "production" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction",
  ]
}

# ============================================================
# PRODUCTION VPC — spoke, private-only. Egress is centralized in the
# network account, so this VPC has no NAT/IGW of its own; the vpc
# module instead adds a 0.0.0.0/0 route to the TGW on every private
# route table (see modules/vpc/main.tf's tgw_id handling).
# ============================================================
module "vpc" {
  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  enable_nat_gateway = false
  tgw_id             = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  tags = var.tags
}

# ============================================================
# TGW attachment. Comes up "available" on its own because the TGW has
# AutoAcceptSharedAttachments = enable — no RAM accepter needed since this
# account and the network account are in the same AWS Organization with
# RAM sharing enabled.
# ============================================================
module "tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "tgw-attach-prod-spoke"
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  tags = var.tags
}

# ============================================================
# TGW route table wiring — spoke-owned. Runs against the network account
# via the aws.network provider (assumes TgwSpokeWiringProduction, scoped
# to only prod_spoke + main).
#
# Associated with prod_spoke only — that's the table development's traffic
# never reaches, so there's no east-west path between the two environments.
# Propagated into BOTH prod_spoke (so this VPC's own table knows about its
# own attachment — required for propagation to work at all) and main (so
# NAT return traffic from the egress VPC has a route back to this VPC).
# This replaces the old inspected_return static route: propagation into
# main achieves the same thing without needing a firewall attachment.
# ============================================================
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment.attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment.attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "main" {
  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment.attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.main_route_table_id.value)
}

# ============================================================
# Default route out of the private subnets, via the TGW.
# Lives here rather than in modules/vpc because a route targeting a TGW is only
# valid once the VPC is attached, and the attachment depends on modules/vpc —
# so the module cannot depend on the attachment. depends_on below is the point.
# ============================================================
resource "aws_route" "private_to_tgw" {
  for_each = { for idx, az in var.azs : az => idx }

  route_table_id         = module.vpc.private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  depends_on = [module.tgw_attachment]

  lifecycle {
    precondition {
      condition     = length(module.vpc.private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc.private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}
