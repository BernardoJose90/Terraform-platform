###############################################################################
# Account: Monitoring
# Purpose: Centralized CloudWatch, dashboards, alarms, X-Ray
###############################################################################

terraform {
  required_version = ">= 1.11.0"
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

# Caps TerraformDeploy to exactly the baseline every account needs — this
# account has no resources of its own yet (see the file header), so no
# extra_policy_json on top. When real CloudWatch/dashboards/alarms/X-Ray
# resources get added here, the first apply that needs new IAM actions
# will fail against this boundary — that's the intended fail-safe: it
# forces a deliberate boundary update alongside the new infrastructure,
# instead of this account silently carrying permissions for infrastructure
# it doesn't have yet.
module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "monitoring"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "monitoring" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"
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

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}
