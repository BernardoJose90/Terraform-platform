###############################################################################################################################################
# Account: Network
# Email  : james.jose109099+aws-network@gmail.com
# Purpose: Shared networking — Transit Gateway, VPCs, Route 53 Resolver
#          This Terraform code sets up centralized networking that will be shared across multiple AWS accounts (development, production, etc.). 
#          using a hub-and-spoke network architecture
###############################################################################################################################################

# Stores the Terraform state in an S3 bucket Uses a separate state file for the network account (network/terraform.tfstate)
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
# =================================================================================
# Provides Management Account Access (SSM Read) to Assumes an SSMReadOnly role in the management account
# Reads the network account ID from SSM Parameter Store iin the Management Account
# =================================================================================
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"

  }
}
# =================================================================================
# Configures the primary AWS provider for the network account
# =================================================================================
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.network_account_id.value]
}

data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}
# =================================================================================
# Creates IAM roles that GitHub Actions can assume via OIDC
# This is the authentication mechanism that allows the pipeline to deploy to this account
# Creates a TerraformDeploy role specifically for the network account
# =================================================================================
module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "network"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = var.management_account_id
  state_bucket_name     = "james-terraform-state-2026"
  role_name             = "TerraformDeploy"

}
# =================================================================================
# Reads the account IDs for development and production from SSM
# These are used later to share the Transit Gateway with those accounts
# =================================================================================
data "aws_ssm_parameter" "dev_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

data "aws_ssm_parameter" "prod_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# =================================================================================
# --- Read Prod/Dev's own TGW attachment IDs from their state files ---
# Reads the Terraform state files from production and development accounts
# This allows the network account to read outputs from those accounts (like their VPC attachment IDs)
# Creates a dependency: network account needs dev/prod to be deployed first
# =================================================================================
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
# =================================================================================
# LOCALS: Safely handle missing prod/dev outputs
# Safely attempts to read the attachment_id output from dev/prod states
# If the output doesn't exist (dev/prod not deployed yet), it defaults to null
# Sets boolean flags indicating whether dev/prod have been applied
# =================================================================================
locals {
  # Try to get attachment IDs from remote state, default to null if not found
  prod_attachment_id = try(data.terraform_remote_state.production.outputs.attachment_id, null)
  dev_attachment_id  = try(data.terraform_remote_state.development.outputs.attachment_id, null)

  # Check if prod/dev have been applied
  prod_applied = local.prod_attachment_id != null
  dev_applied  = local.dev_attachment_id != null
}

# =================================================================================
# --- The NAT/egress VPC — the only VPC with an IGW + NAT GW ---
# Creates a VPC with public and private subnets across 2 availability zones
# Enables NAT Gateways (one per AZ) for private subnets to access the internet
# This VPC serves as the internet gateway for all other accounts
# Traffic from dev/prod goes through this VPC's NAT Gateways to reach the internet
# =================================================================================

module "nat_vpc2" {
  source = "../../modules/vpc"

  name = "Network-Nat-Vpc2"
  cidr = "10.20.0.0/16"

  azs             = ["eu-west-2a", "eu-west-2b"]
  private_subnets = ["10.20.30.0/24", "10.20.40.0/24"]
  public_subnets  = ["10.20.50.0/24", "10.20.60.0/24"]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true

  tags = { Environment = "network" }

}

/* 
# =================================================================================
# Creates a Transit Gateway (central network hub)
# Shares the TGW with dev and prod accounts via AWS RAM (Resource Access Manager)
# nonsensitive() tells Terraform this isn't sensitive data
# =================================================================================
module "tgw" {
  source = "../../modules/tgw"

  name = "core-tgw"

  share_with_principals = [
    nonsensitive(data.aws_ssm_parameter.dev_account_id.value),
    nonsensitive(data.aws_ssm_parameter.prod_account_id.value)
  ]
  tags = { Environment = "network" }
}

# =================================================================================
# SSM PARAMETERS (for prod/dev to discover TGW)
# =================================================================================
# Stores the TGW ID and route table IDs in SSM
# Dev and prod accounts can read these to attach to the TGW
# This is how accounts discover the network infrastructure
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
  name  = "/transit-gateway/development/dev-spoke-rt-id"
  type  = "String"
  value = module.tgw.tgw_route_table_ids.dev_spoke
  tags  = { Environment = "network" }
}
# =================================================================================

# =================================================================================
# --- TGW Attachment for NAT VPC ---
# Attaches the NAT VPC to the Transit Gateway
# Uses private subnets so traffic flows through NAT Gateways
# =================================================================================
module "nat_vpc_tgw_attachment" {
  source = "../../modules/tgw-attachment"

  name       = "network-nat-vpc"
  tgw_id     = module.tgw.tgw_id
  vpc_id     = module.nat_vpc.vpc_id
  subnet_ids = module.nat_vpc.private_subnet_ids

  tags = { Environment = "network" }
}

# =================================================================================
# Network Firewall — TGW-attached mode
# Deploys AWS Network Firewall
# Inspects all traffic passing through the Transit Gateway
# Provides centralized security policy (like a traditional firewall)
# Can block malicious traffic, enforce compliance, etc.
=================================================================================
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

# =================================================================================
# ROUTES: Conditional modules that only create routes if prod/dev exist
# --- Routes for firewall_forwarding route table ---
# This is where traffic goes AFTER inspection
# =================================================================================
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

# =====================================================================================================
# Everything goes to firewall for inspection first
# Only creates routes if prod/Devaccount has been deployed (count = local.prod_applied ? 1 : 0)
# Routes all traffic from prod (0.0.0.0/0) and traffic to dev (10.30.0.0/16) through the firewall
# This ensures all traffic is inspected
# Conditional logic prevents errors if prod/dev haven't been deployed yet
# =====================================================================================================
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
*/
