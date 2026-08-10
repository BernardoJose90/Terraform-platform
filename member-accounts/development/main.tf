###############################################################################
# Account: Development
# Email  : james.jose109099+aws-dev@gmail.com
# Purpose: Dev workload hosting
###############################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # NOTE: this account is currently locked to 5.100.0 while network and
      # production are on 6.x. Worth aligning in a separate change —
      # terraform init -upgrade, then commit .terraform.lock.hcl.
      version = ">= 5.83.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "development/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# ✅ Provider for reading SSM from management account (assumes cross-account role)
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

# ✅ Read the development account ID from SSM
data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# Read the network account ID from SSM (management account) — needed to
# construct the TGW spoke-wiring role ARN below.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# ✅ Main provider for the development account itself — no profile needed
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.development_account_id.value]

}

# Assumes a role in the network account that's scoped to ONLY dev_spoke +
# main (modules/tgw-spoke-wiring-role) — this account can never touch
# tgw-prod-spoke-rt. Replaces terraform_remote_state, which read the
# network account's entire state file and, worse, made network's own
# plan depend on this account's output — a cycle neither account could
# apply cleanly on its own. See member-accounts/network/main.tf for the
# other half.
provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringDevelopment"
  }
}

# Published by the network account. Read via the aws.network role instead
# of terraform_remote_state, so this account's plan role never needs S3
# read access to the network account's full state file.
data "aws_ssm_parameter" "tgw_id" {
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "dev_spoke_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/dev_spoke"
}

# The "main" table is the one narrow surface this account shares write
# access to with production — used only to propagate this VPC's own
# return route, never to touch prod_spoke.
data "aws_ssm_parameter" "main_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "development"

  # GitHub repository information (case-sensitive!)
  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  # AWS account configuration
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "development" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringDevelopment",
  ]
}

# ============================================================
# DEVELOPMENT VPC — spoke, private-only. Egress is centralised in the
# network account, so this VPC has no NAT/IGW of its own. The 0.0.0.0/0
# route to the TGW is added below, AFTER the attachment exists.
# ============================================================
module "vpc" {
  source = "../../modules/vpc"

  name = "development-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  enable_nat_gateway = false
  tgw_id             = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  tags = var.tags
}

# ============================================================
# NO aws_ram_resource_share_accepter HERE — and that is deliberate.
#
# This account and the network account are both in the same AWS Organization
# with RAM sharing enabled, so the TGW share is auto-accepted and no invitation
# is ever created. The accepter resource has nothing to accept: it polls for a
# non-existent invitation and the apply HANGS on "Still creating..." until it
# times out.
#
# Confirmed by:
#   aws ram get-resource-share-invitations --region eu-west-2   -> empty
#   aws ec2 describe-transit-gateways --transit-gateway-ids ... -> succeeds
#
# The Terraform provider docs say the same: "If both AWS accounts are in the same
# Organization and RAM Sharing with AWS Organizations is enabled, this resource is
# not necessary as RAM Resource Share invitations are not used."
# ============================================================

# ============================================================
# TGW attachment. Comes up "available" on its own because the TGW has
# AutoAcceptSharedAttachments = enable.
# ============================================================
module "tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "dev-spoke"
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  tags = var.tags
}

# ============================================================
# TGW route table wiring — spoke-owned. Runs against the network account
# via the aws.network provider (assumes TgwSpokeWiringDevelopment, scoped
# to only dev_spoke + main).
#
# Associated with dev_spoke only — that's the table production's traffic
# never reaches, so there's no east-west path between the two environments.
# Propagated into BOTH dev_spoke (so this VPC's own table knows about its
# own attachment — required for propagation to work at all) and main (so
# NAT return traffic from the egress VPC has a route back to this VPC).
# This replaces the old inspected_return static route: propagation into
# main achieves the same thing without needing a firewall attachment.
# ============================================================
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment.attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.dev_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment.attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.dev_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "main" {
  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment.attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.main_route_table_id.value)
}

# ============================================================
# Default route out of the private subnets, via the TGW.
#
# This lives HERE rather than inside modules/vpc because of ordering: a route
# targeting a TGW is only valid once the VPC is actually attached to it, and the
# attachment depends on modules/vpc. Inside the module the route would always be
# created first and the provider would retry until the 5m timeout.
# depends_on below is the whole point of this block's location.
#
# for_each keys come from var.azs (static, known at plan time), NOT from
# module.vpc.private_route_table_ids (known only after apply). Keying off the
# route table IDs produces:
#   Error: Invalid for_each argument ... cannot be determined until apply
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
# re-verify 2026-08-10T17:17:32Z — safe to delete
