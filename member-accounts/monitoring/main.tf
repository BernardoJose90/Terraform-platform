###############################################################################
# Account: Monitoring
# Purpose: Centralized CloudWatch, dashboards, alarms, X-Ray
###############################################################################

terraform {
  required_version = "~> 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

# Provider for reading SSM from the management account (cross-account role).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "monitoring_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/monitoring"
}

# Main provider for the monitoring account itself, no profile needed.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.monitoring_account_id.value]
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "monitoring"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "monitoring" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"
}
