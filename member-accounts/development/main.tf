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
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"   # same bucket as management
    key          = "development/terraform.tfstate"  # different key
    region       = "eu-west-2"
    use_lockfile = true                            # native S3 locking
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}

module "terraform_deploy_role" {
  source                = "../modules/terraform-deploy-role"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
}

module "vpc" {
  source = "../../modules/vpc"
  name   = "dev-vpc"
  cidr   = "10.0.0.0/16"
}


