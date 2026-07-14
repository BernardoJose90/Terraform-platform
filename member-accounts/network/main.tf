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

# ✅ Provider for reading SSM from management account (assumes cross-account role)
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

# ✅ Read the network account ID from SSM
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# ✅ Main provider for the network account itself — no profile needed
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.network_account_id.value]
}

# ✅ module to create terraform deploy role in network account
module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "network"

  # GitHub repository information (case-sensitive!)
  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  # AWS account configuration
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  role_name             = "TerraformDeploy"
}

# ✅ Read the development account ID from SSM
data "aws_ssm_parameter" "dev_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# ✅ Read the production account ID from SSM
data "aws_ssm_parameter" "prod_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}


# The NAT/egress VPC — the only VPC in the whole setup with an IGW + NAT GW. /*  */
/* 
module "nat_vpc" {
  source = "../../modules/vpc"

  name = "network-nat-vpc"
  cidr = "10.99.0.0/16"

  azs             = ["eu-west-2a", "eu-west-2b"]
  private_subnets = ["10.99.1.0/24", "10.99.2.0/24"]     # TGW attachment subnets
  public_subnets  = ["10.99.101.0/24", "10.99.102.0/24"] # NAT GW + IGW live here

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true # real HA — one NAT GW per AZ, no single point of failure

  tags = { Environment = "network" }
}
*/

/* 
module "tgw" {
  source = "../../modules/tgw"

  name = "core-tgw"

  # Org ARN shares with every account in the org; swap for a list of
  # specific account IDs if you'd rather be explicit.
  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.dev_account_id.value),
    nonsensitive(data.aws_ssm_parameter.prod_account_id.value)
  ]
  tags = { Environment = "network" }
}
*/

/*
module "nat_vpc_tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name               = "network-nat-vpc"
  tgw_id             = module.tgw.tgw_id
  tgw_route_table_id = module.tgw.tgw_route_table_id
  vpc_id             = module.nat_vpc.vpc_id
  subnet_ids         = module.nat_vpc.private_subnet_ids

  tags = { Environment = "network" }
}
*/

# Send spoke-bound-for-internet traffic arriving at the NAT VPC out through
# its NAT Gateways. (The NAT VPC's own private_to_tgw route isn't created
# here since we didn't pass tgw_id into module.nat_vpc — this VPC IS the
# egress point, so its private subnets already route 0.0.0.0/0 to NAT.).

/*
output "tgw_id" {
  value = module.tgw.tgw_id
}


output "tgw_route_table_id" {
  value = module.tgw.tgw_route_table_id
}
*/