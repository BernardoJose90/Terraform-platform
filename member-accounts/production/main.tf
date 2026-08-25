#############################################################################################################
# Account: Production
# Runs the live app — EKS, RDS, an internal ALB. This VPC is private
# only, with no direct internet gateway or NAT of its own: all outbound
# traffic goes out through the network account's setup instead, over the
# Transit Gateway (TGW). To reach the network account, this account
# assumes a role (TgwSpokeWiringProduction) that can only touch its own
# route table plus one shared "main" table — never development's. TGW
# details come from SSM parameters the network account publishes, not
# from reading its Terraform state directly. Everything in this file can
# be switched off with var.networking_enabled.
#############################################################################################################

terraform {
  required_version = "~> 1.11.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Aligned with network (see member-accounts/network/main.tf). The
      # lock file already resolves to 6.x; this just makes it explicit
      # instead of silently floating on whatever ">= 5.83.0" resolves to.
      version = "~> 6.0"
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

# Provider for reading SSM from the management account (account ID only).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# Needed to construct the TGW spoke-wiring role ARN below.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# Main provider for the production account itself.
# this provider is used for creating resources in the production account, such as VPCs, subnets, and route tables.
# It is configured to only allow access to the production account ID retrieved from SSM.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]
}

# Assumes a role in the network account that's locked to just this
# account's own route table plus "main" (modules/tgw-spoke-wiring-role) —
# this account can never touch development's route table.

# this provider is used for reading SSM parameters and creating resources in the network account, such as Transit Gateway route table associations and propagations.
# It is configured to assume a role in the network account that allows access to the production account's route table and the main route table of the Transit Gateway (TGW).
provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction"
  }
}

# this data source retrieves the Transit Gateway (TGW) ID from the SSM parameter store in the network account, 
# allowing the production account to reference the TGW for routing and attachment purposes.
data "aws_ssm_parameter" "tgw_id" {
  provider = aws.network
  name     = "/transit-gateway/id"
}

# this data source retrieves the production spoke route table ID from the SSM parameter store in the network account,
# allowing the production account to reference its own route table for routing and attachment purposes.
data "aws_ssm_parameter" "prod_spoke_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/prod_spoke"
}

# this data source retrieves the main route table ID from the SSM parameter store in the network account,
# allowing the production account to reference the main route table of the Transit Gateway (TGW)
# never to reach into the other's own table.
data "aws_ssm_parameter" "main_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

# this local variable defines the ARN of the role in the network account that allows the production account to wire itself into the Transit Gateway (TGW).
locals {
  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction",
  ]
}

# this module creates a permissions boundary in the production account that restricts the actions that can be performed by the Terraform deploy role in production.
module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "production"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "production"
  role_name             = "TerraformDeploy"

  # this flag enables VPC networking in the production account, allowing the creation of VPCs, subnets, and route tables for the production workloads.
  enable_vpc_networking = true

# this variable defines the ARNs of the roles that can be assumed by the Terraform deploy role in production, allowing it to perform actions on behalf of those roles.
  extra_assumable_role_arns = local.extra_assumable_role_arns
}

# this module creates a GitHub OIDC role called TerraformDeploy in the production account that allows GitHub Actions workflows to assume the Terraform deploy role in production.
# this role is granted permissions to perform actions on behalf of the Terraform deploy role, allowing GitHub Actions workflows to deploy infrastructure in the production account.
module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "production"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "production"
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = local.extra_assumable_role_arns

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}

# ============================================================
# PRODUCTION VPC — private only, no NAT/internet gateway of its own,
# since outbound traffic goes through the network account instead. The
# vpc module handles this by adding a catch-all route to the TGW on
# every private route table (see modules/vpc/main.tf's tgw_id handling).
# ============================================================
module "vpc" {
  count = var.networking_enabled ? 1 : 0


  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  # this private_subnet_names variable defines the names of the private subnets in the production VPC, based on the availability zones (AZs) specified in the var.azs variable.
  private_subnet_names = [for az in var.azs : "production-Twg-private-sub-${az}"]

  # this enable_nat_gateway variable disables the creation of a NAT gateway in the production VPC, since outbound traffic is routed through the network account's Transit Gateway (TGW) instead.
  enable_nat_gateway = false

  # this tgw_id variable retrieves the Transit Gateway (TGW) ID from the SSM parameter store in the network account, allowing the production VPC to route traffic through the TGW for outbound connectivity.
  tgw_id             = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  tags = var.tags
}

# This connects the VPC to the TGW. It gets approved automatically —
# the TGW is set to auto-accept connections, and since this account and
# network are in the same AWS Organization with sharing turned on, there's
# no manual accept step needed.

# this module creates a Transit Gateway (TGW) attachment in the production account that connects the production VPC to the Transit Gateway (TGW) in the network account.
module "tgw_attachment" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-attachment"

  name = "tgw-attach-prod-spoke"
  # This block turns on/off with the exact same condition as module.vpc
  # above, so whenever it exists, the VPC definitely exists too — safe
  # to reference module.vpc[0] below.
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)
  vpc_id     = module.vpc[0].vpc_id
  subnet_ids = module.vpc[0].private_subnet_ids

  tags = var.tags
}

# ============================================================
# This wires the VPC into the TGW's routing, run against the network
# account using the scoped-down role from above. Only linked to this
# account's own route table (prod_spoke) — there's no direct path
# between production and development traffic. Also propagated (announced
# as a valid route) into prod_spoke itself, which the link needs to work
# at all, and into "main", so return traffic from NAT can find its way
# back here.
# ============================================================


# this resource block associates the Transit Gateway (TGW) attachment for the production VPC with the production spoke route table in the network account, 
# allowing traffic from the production VPC to be routed through the TGW and reach other spoke accounts.
resource "aws_ec2_transit_gateway_route_table_association" "tgw_rtb_association" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}
# this resource block propagates the routes from the production VPC's Transit Gateway (TGW) attachment into the production spoke route table in the network account,
# allowing the production VPC to announce its routes to other spoke accounts through the TGW.
resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}


# this resource block propagates the routes from the production VPC's Transit Gateway (TGW) attachment into the main route table of the Transit Gateway (TGW) in the network account,
# allowing the production VPC to announce its routes to other spoke accounts through the TGW
resource "aws_ec2_transit_gateway_route_table_propagation" "main" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.main_route_table_id.value)
}

# ============================================================
# Sends outbound traffic from the private subnets to the TGW. This has
# to live here rather than inside modules/vpc: a route can't point at
# the TGW until the VPC is actually connected to it, and that connection
# is created AFTER modules/vpc runs — so modules/vpc has no way to wait
# for something that doesn't exist yet when it runs. depends_on below is
# the entire reason this lives out here instead.
# ============================================================

# this resource block creates routes in the private route tables of the production VPC to send outbound traffic destined for the internet 
resource "aws_route" "private_to_tgw" {

  for_each = var.networking_enabled ? { for idx, az in var.azs : az => idx } : {}

  # this route_table_id variable retrieves the private route table IDs from the production VPC module, 
  # allowing the creation of routes in each private route table for outbound traffic to the Transit Gateway (TGW).
  route_table_id         = module.vpc[0].private_route_table_ids[each.value]

  # this destination_cidr_block variable defines the CIDR block for the route, which is set to "
  destination_cidr_block = "0.0.0.0/0"

  # this transit_gateway_id variable retrieves the Transit Gateway (TGW) ID from the SSM parameter store in the network account, 
  # allowing the route to point to the TGW for outbound traffic.
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  # this depends_on variable ensures that the route creation waits for the Transit Gateway (TGW) attachment to be created before creating the routes,  
  # preventing any potential issues with routing traffic to the TGW before the attachment is established.
  depends_on = [module.tgw_attachment]

  # this lifecycle block defines a precondition that checks if the number of private route tables in the production VPC matches the number of availability zones (AZs) specified in the var.azs variable.
  lifecycle {
    precondition {
      condition     = length(module.vpc[0].private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc[0].private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}

# ============================================================
# Subnets for production's own apps — EKS, RDS, an internal ALB, and a
# general-purpose tier. Kept as its own module rather than folded into
# modules/vpc, since network and development don't need to know anything
# about how production's app is laid out. Only eks and resources get a
# route out to the TGW — rds and alb deliberately don't, since neither a
# database nor an internal load balancer should ever be initiating
# outbound traffic on its own.
#
# TEARDOWN FLAG: turns off with everything else that depends on the VPC.
# ============================================================

# this module creates subnets for the production workloads, including EKS, RDS, an internal ALB, and a general-purpose tier.
# this module is kept separate from the VPC module to avoid exposing production workload details to the network and development accounts.
# this module also configures the route tables for the subnets, allowing EKS and resources subnets to route outbound traffic through the Transit Gateway (TGW), 
# while RDS and ALB subnets do not have outbound routes to the TGW.
module "prod_purpose_subnets" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/prod-purpose-subnets"
  # this vpc_id variable retrieves the VPC ID from the production VPC module, allowing the creation of subnets within the production VPC.
  vpc_id = module.vpc[0].vpc_id

  # this tgw_id variable retrieves the Transit Gateway (TGW) ID from the SSM parameter store in the network account, 
  # allowing the production workloads to route outbound traffic through the TGW.
  tgw_id = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  # this production_workload_subnets variable defines the subnets for the production workloads, including EKS, RDS, an internal ALB, and a general-purpose tier.
  production_workload_subnets = {
    eks = {
      route_table_name = "prod-eks-rtb"
      to_tgw           = true
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.30.0/24", name = "prod-eks-a" }
        b = { az = "eu-west-2b", cidr = "10.20.40.0/24", name = "prod-eks-b" }
      }
    }
    rds = {
      route_table_name = "prod-rds-rtb"
      to_tgw           = false
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.50.0/24", name = "prod-rds-a" }
        b = { az = "eu-west-2b", cidr = "10.20.60.0/24", name = "prod-rds-b" }
      }
    }
    alb = {
      route_table_name = "prod-private-alb-rtb"
      to_tgw           = false
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.70.0/24", name = "prod-alb-a" }
        b = { az = "eu-west-2b", cidr = "10.20.80.0/24", name = "prod-alb-b" }
      }
    }
    resources = {
      route_table_name = "prod-private-resources-rtb"
      to_tgw           = true
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.20.100.0/24", name = "prod-private-resources" }
      }
    }
  }

  tags = var.tags

  # this depends_on variable ensures that the subnet creation waits for the Transit Gateway (TGW) attachment to be created before creating the subnets,
  # preventing any potential issues with routing traffic to the TGW before the attachment is established.
  depends_on = [module.tgw_attachment]
}
