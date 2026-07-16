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
    bucket       = "james-terraform-state-2026"
    key          = "network/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.network_account_id.value]
}

module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "network"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  role_name             = "TerraformDeploy"
}

data "aws_ssm_parameter" "dev_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

data "aws_ssm_parameter" "prod_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# --- Read Prod/Dev's own TGW attachment IDs from their state files ---
# Prod and Dev create their own tgw-attachment resource (it must run in the
# spoke account per that module's design), then output attachment_id. We
# read it here via remote state since all accounts share one state bucket.
data "terraform_remote_state" "production" {
  backend = "s3"
  config = {
    bucket = "james-terraform-state-2026"
    key    = "production/terraform.tfstate"
    region = "eu-west-2"
  }
}

data "terraform_remote_state" "development" {
  backend = "s3"
  config = {
    bucket = "james-terraform-state-2026"
    key    = "development/terraform.tfstate"
    region = "eu-west-2"
  }
}

# --- The NAT/egress VPC — the only VPC with an IGW + NAT GW ---
module "nat_vpc" {
  source = "../../modules/vpc"

  name = "network-nat-vpc"
  cidr = "10.99.0.0/16"

  azs             = ["eu-west-2a", "eu-west-2b"]
  private_subnets = ["10.99.1.0/24", "10.99.2.0/24"]
  public_subnets  = ["10.99.101.0/24", "10.99.102.0/24"]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true

  tags = { Environment = "network" }
}

module "tgw" {
  source = "../../modules/tgw"

  name = "core-tgw"

  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.dev_account_id.value),
    nonsensitive(data.aws_ssm_parameter.prod_account_id.value)
  ]
  tags = { Environment = "network" }
}

# Egress VPC's attachment associates with the firewall_forwarding table —
# it only ever receives already-inspected traffic, same as the firewall's
# own attachment.
module "nat_vpc_tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name                = "network-nat-vpc"
  tgw_id              = module.tgw.tgw_id
  tgw_route_table_id = module.tgw.tgw_route_table_ids.firewall_forwarding
  vpc_id              = module.nat_vpc.vpc_id
  subnet_ids          = module.nat_vpc.private_subnet_ids

  tags = { Environment = "network" }
}

# --- The firewall itself ---
module "network_firewall" {
  source = "../../modules/network-firewall"

  name                                     = "core-network-firewall"
  tgw_id                                     = module.tgw.tgw_id
  tgw_firewall_forwarding_route_table_id = module.tgw.tgw_route_table_ids.firewall_forwarding
  availability_zones                       = ["eu-west-2a", "eu-west-2b"] # verify these match your AZ-ID format

  prod_cidr = "10.20.0.0/16"
  dev_cidr   = "10.30.0.0/16"

  tags = { Environment = "network" }
}

output "tgw_id" {
  value = module.tgw.tgw_id
}

output "tgw_route_table_ids" {
  value = module.tgw.tgw_route_table_ids
}

# tgw-firewall-forwarding-rt: post-inspection routing to real destinations
module "routes_firewall_forwarding" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids.firewall_forwarding
  routes = {
    "10.20.0.0/16" = data.terraform_remote_state.production.outputs.attachment_id
    "10.30.0.0/16" = data.terraform_remote_state.development.outputs.attachment_id
    "0.0.0.0/0"     = module.nat_vpc_tgw_attachment.attachment_id
  }
}

# tgw-prod-spoke-rt: everything not local goes to the firewall for inspection
module "routes_prod_spoke" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids.prod_spoke
  routes = {
    "0.0.0.0/0"     = module.network_firewall.tgw_attachment_id
    "10.30.0.0/16" = module.network_firewall.tgw_attachment_id
  }
}

# tgw-dev-spoke-rt: mirror of prod
module "routes_dev_spoke" {
  source = "../../modules/tgw-static-routes"

  tgw_route_table_id = module.tgw.tgw_route_table_ids.dev_spoke
  routes = {
    "0.0.0.0/0"     = module.network_firewall.tgw_attachment_id
    "10.20.0.0/16" = module.network_firewall.tgw_attachment_id
  }
}