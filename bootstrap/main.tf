terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

locals {
  management_account_id = "145678291484"
}

module "production_deploy_role" {
  source                = "../modules/terraform-deploy-role"
  providers             = { aws = aws.production }
  management_account_id = local.management_account_id
}

module "network_deploy_role" {
  source                = "../modules/terraform-deploy-role"
  providers             = { aws = aws.network }
  management_account_id = local.management_account_id
}

module "security_deploy_role" {
  source                = "../modules/terraform-deploy-role"
  providers             = { aws = aws.security }
  management_account_id = local.management_account_id
}

output "role_arns" {
  value = {
    production = module.production_deploy_role.role_arn
    network    = module.network_deploy_role.role_arn
    security   = module.security_deploy_role.role_arn
  }
}