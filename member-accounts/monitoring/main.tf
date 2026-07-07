###############################################################################
# Account: Monitoring
# Email  : james.jose109099+aws-monitor@gmail.com
# Purpose: Centralized CloudWatch, dashboards, alarms, X-Ray
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
    key          = "monitoring/terraform.tfstate" # different key
    region       = "eu-west-2"
    use_lockfile = true # native S3 locking
    encrypt      = true

  }
}

provider "aws" {
  region = var.aws_region
}

module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "monitoring" # change per account
}