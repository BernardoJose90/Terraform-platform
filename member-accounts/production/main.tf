###############################################################################
# Account: Production
# Email  : james.jose109099+aws-prod@gmail.com
# Purpose: Live workload hosting
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
    key          = "production/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# ✅ Provider for reading SSM from management account (for account ID only)
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

# ✅ Read the production account ID from SSM (management account)
data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# ✅ Main provider for the production account itself
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]
}

# ✅ Read network account's state directly (NO cross-account IAM needed)
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
  account_name = "production"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  role_name             = "TerraformDeploy"
}

# ============================================================
# PRODUCTION VPC
# ============================================================
module "prod_vpc" {
  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = "10.20.0.0/16"

  azs             = ["eu-west-2a", "eu-west-2b"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24"]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

# ============================================================
# TGW ATTACHMENT FOR PRODUCTION VPC
# ============================================================
# Read TGW info directly from network account's state
module "prod_tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "production-vpc"
  tgw_id     = data.terraform_remote_state.network.outputs.tgw_id
  vpc_id     = module.prod_vpc.vpc_id
  subnet_ids = module.prod_vpc.private_subnet_ids

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

# ============================================================
# OUTPUTS (for network account to reference)
# ============================================================
output "attachment_id" {
  description = "The TGW attachment ID for the production VPC"
  value       = module.prod_tgw_attachment.attachment_id
}

output "vpc_id" {
  description = "The production VPC ID"
  value       = module.prod_vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs in the production VPC"
  value       = module.prod_vpc.private_subnet_ids
}
