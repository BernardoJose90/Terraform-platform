###############################################################################
# Account: Monitoring
# Purpose: will hold centralized observability tooling — CloudWatch
# (AWS's metrics/logs service), dashboards, alarms, and X-Ray (AWS's
# distributed tracing service). At the moment, this account only has its
# baseline setup (deploy role, CI/CD roles); none of that observability
# infrastructure exists here yet.
###############################################################################

terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"   # same S3 bucket used by the management account
    key          = "monitoring/terraform.tfstate" # but a different file path (key) within that bucket
    region       = "eu-west-2"
    use_lockfile = true # uses S3's built-in locking, so concurrent applies don't corrupt the state file
    encrypt      = true

  }
}

# Provider used to read parameters from AWS Systems Manager (SSM) Parameter Store in the management account, by assuming a role in that account.
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

# The main provider for the monitoring account itself — no assumed role needed since Terraform runs directly as this account.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.monitoring_account_id.value]
}

# Limits the TerraformDeploy role to exactly the baseline permissions
# every account needs — nothing more. This account has no resources of
# its own yet (see the file header above), so there's no extra permission
# policy (extra_policy_json) added on top of the baseline. When real
# CloudWatch, dashboard, alarm, or X-Ray resources are eventually added
# here, the first deployment that needs a new AWS permission will fail
# against this permissions boundary. That failure is intentional: it
# forces someone to deliberately update the boundary at the same time as
# adding the new infrastructure, instead of this account silently
# carrying permissions for infrastructure it doesn't actually have yet.
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
