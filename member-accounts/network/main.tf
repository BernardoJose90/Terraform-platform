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
      version = ">= 5.83.0"
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

/* */
# ============================================================
# LOCALS: Safely handle missing prod/dev outputs
# ============================================================
locals {
  # Try to get attachment IDs from remote state, default to null if not found
  prod_attachment_id = try(data.terraform_remote_state.production.outputs.attachment_id, null)
  dev_attachment_id  = try(data.terraform_remote_state.development.outputs.attachment_id, null)

  # Check if prod/dev have been applied
  prod_applied = local.prod_attachment_id != null
  dev_applied  = local.dev_attachment_id != null
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

# ============================================================
# SSM PARAMETERS (for prod/dev to discover TGW)
# ============================================================
resource "aws_ssm_parameter" "tgw_id" {
  name  = "/transit-gateway/production/tgw-id"
  type  = "String"
  value = module.tgw.tgw_id
  tags  = { Environment = "network" }
}

resource "aws_ssm_parameter" "prod_spoke_route_table_id" {
  name  = "/transit-gateway/production/prod-spoke-rt-id"
  type  = "String"
  value = module.tgw.tgw_route_table_ids.prod_spoke
  tags  = { Environment = "network" }
}

resource "aws_ssm_parameter" "dev_spoke_route_table_id" {
  name  = "/transit-gateway/production/dev-spoke-rt-id"
  type  = "String"
  value = module.tgw.tgw_route_table_ids.dev_spoke
  tags  = { Environment = "network" }
}

# --- TGW Attachment for NAT VPC ---
# Associate with firewall_forwarding route table (post-inspection)
module "nat_vpc_tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name               = "network-nat-vpc"
  tgw_id             = module.tgw.tgw_id
  tgw_route_table_id = module.tgw.tgw_route_table_ids.firewall_forwarding
  vpc_id             = module.nat_vpc.vpc_id
  subnet_ids         = module.nat_vpc.private_subnet_ids

  tags = { Environment = "network" }
}

# ============================================================
# Network Firewall — TGW-attached mode
# ============================================================
# The firewall runs in an AWS-managed VPC, not in the NAT VPC
module "network_firewall" {
  source = "../../modules/network-firewall"

  name                                   = "core-network-firewall"
  tgw_id                                 = module.tgw.tgw_id
  availability_zones                     = ["eu-west-2a", "eu-west-2b"]
  tgw_firewall_forwarding_route_table_id = module.tgw.tgw_route_table_ids.firewall_forwarding

  prod_cidr = "10.20.0.0/16"
  dev_cidr  = "10.30.0.0/16"

  tags = { Environment = "network" }
}

# --- Outputs ---
output "tgw_id" {
  value = module.tgw.tgw_id
}

output "tgw_route_table_ids" {
  value = module.tgw.tgw_route_table_ids
}

output "firewall_tgw_attachment_id" {
  value = module.network_firewall.tgw_attachment_id
}

# ============================================================
# ROUTES: Conditional modules that only create routes if prod/dev exist
# ============================================================

# --- Routes for firewall_forwarding route table ---
# This is where traffic goes AFTER inspection
module "routes_firewall_forwarding" {
  source = "../../modules/tgw-static-routes"

  count = local.prod_applied && local.dev_applied ? 1 : 0

  tgw_route_table_id = module.tgw.tgw_route_table_ids.firewall_forwarding
  routes = {
    "10.20.0.0/16" = local.prod_attachment_id
    "10.30.0.0/16" = local.dev_attachment_id
    "0.0.0.0/0"    = module.nat_vpc_tgw_attachment.attachment_id
  }
}

# --- Routes for prod_spoke route table ---
# Everything goes to firewall for inspection first
module "routes_prod_spoke" {
  source = "../../modules/tgw-static-routes"

  count = local.prod_applied ? 1 : 0

  tgw_route_table_id = module.tgw.tgw_route_table_ids.prod_spoke
  routes = {
    "0.0.0.0/0"    = module.network_firewall.tgw_attachment_id
    "10.30.0.0/16" = module.network_firewall.tgw_attachment_id
  }
}

# --- Routes for dev_spoke route table ---
module "routes_dev_spoke" {
  source = "../../modules/tgw-static-routes"

  count = local.dev_applied ? 1 : 0

  tgw_route_table_id = module.tgw.tgw_route_table_ids.dev_spoke
  routes = {
    "0.0.0.0/0"    = module.network_firewall.tgw_attachment_id
    "10.20.0.0/16" = module.network_firewall.tgw_attachment_id
  }
}

# ============================================================
# NOTIFICATIONS: Inform if prod/dev routes are missing
# ============================================================
output "routes_status" {
  value = {
    prod_routes_created = local.prod_applied
    dev_routes_created  = local.dev_applied
    message             = local.prod_applied && local.dev_applied ? "✅ All routes to prod/dev have been created." : "⚠️ Prod/dev routes not created. Apply production and development accounts first, then run 'terraform apply' again."
  }
}

