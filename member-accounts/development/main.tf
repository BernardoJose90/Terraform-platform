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

# ✅ Main provider for the development account itself — no profile needed
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.development_account_id.value]

}

# Read network account's state directly (NO cross-account IAM needed)
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "james-terraform-state-2026"
    key    = "network/terraform.tfstate"
    region = "eu-west-2"
  }
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
  role_name             = "TerraformDeploy"
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
  tgw_id             = data.terraform_remote_state.network.outputs.tgw_id

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
# TGW attachment — associated by the network account with the
# dev_spoke route table once this account's state is applied.
# Comes up "available" on its own because the TGW has
# AutoAcceptSharedAttachments = enable.
# ============================================================
module "tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "dev-spoke"
  tgw_id     = data.terraform_remote_state.network.outputs.tgw_id
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  tags = var.tags
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
  transit_gateway_id     = data.terraform_remote_state.network.outputs.tgw_id

  depends_on = [module.tgw_attachment]

  lifecycle {
    precondition {
      condition     = length(module.vpc.private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc.private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}

