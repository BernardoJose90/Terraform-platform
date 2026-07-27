###############################################################################
# Account: Development 
# Email  : james.jose109099+aws-dev@gmail.com
# Purpose: Dev workload hosting
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

# ✅ Read the production account ID from SSM
data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# ✅ Main provider for the production account itself — no profile needed
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
# DEVELOPMENT VPC — spoke, private-only. Egress is centralized in the
# network account, so this VPC has no NAT/IGW of its own; the vpc
# module instead adds a 0.0.0.0/0 route to the TGW on every private
# route table (see modules/vpc/main.tf's tgw_id handling).
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
# Accept the TGW's RAM share from the network account before
# attempting the VPC attachment below — the attachment fails until
# this account has accepted the share.
# ============================================================
resource "aws_ram_resource_share_accepter" "tgw" {
  share_arn = data.terraform_remote_state.network.outputs.ram_resource_share_arn
}

# ============================================================
# TGW attachment — associated by the network account with the
# dev_spoke route table once this account's state is applied.
# ============================================================
module "tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "dev-spoke"
  tgw_id     = data.terraform_remote_state.network.outputs.tgw_id
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  tags = var.tags

  depends_on = [aws_ram_resource_share_accepter.tgw]
}

