###############################################################################
# Account: Network
# Email  : james.jose109099+aws-network@gmail.com
# Purpose: Shared networking — Transit Gateway, VPCs, Route 53 Resolver
###############################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026" # same bucket as management
    key          = "network/terraform.tfstate"  # different key
    region       = "eu-west-2"
    use_lockfile = true # native S3 locking
    encrypt      = true
  }
}

# ✅ Provider for reading SSM from management account
provider "aws" {
  alias   = "management"
  region  = var.aws_region
  profile = "management"
}

# ✅ Read the development account ID from SSM
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# ✅ Provider for Development account - NO assume_role needed!
provider "aws" {
  region  = var.aws_region
  profile = "network" # 👈 Uses your SSO profile directly

  # ✅ This ensures we only deploy to the development account
  allowed_account_ids = [data.aws_ssm_parameter.network_account_id.value]


}

module "vpc" {
  source = "../../modules/vpc"
  name   = "network-vpc"
  cidr   = "10.1.0.0/16"
  }

module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "network" # change per account
}
