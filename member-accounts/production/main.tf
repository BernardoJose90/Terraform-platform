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
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]
}

# Assumes a role in the network account that's locked to just this
# account's own route table plus "main" (modules/tgw-spoke-wiring-role) —
# this account can never touch development's route table.
provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction"
  }
}

# Published by the network account, and read using the aws.network role
# above instead of reading network's Terraform state file directly — so
# this account's read-only plan role never needs access to that state.
data "aws_ssm_parameter" "tgw_id" {
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "prod_spoke_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/prod_spoke"
}

# "main" is the one shared table this account and development both get
# write access to — used only so each can publish its own return route,
# never to reach into the other's own table.
data "aws_ssm_parameter" "main_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "production"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "production"
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction",
  ]
}

# ============================================================
# PRODUCTION VPC — private only, no NAT/internet gateway of its own,
# since outbound traffic goes through the network account instead. The
# vpc module handles this by adding a catch-all route to the TGW on
# every private route table (see modules/vpc/main.tf's tgw_id handling).
# ============================================================
module "vpc" {
  count = var.networking_enabled ? 1 : 0

  # This VPC and module.github-oidc-roles (which sets up this account's
  # own CI permissions) can sometimes run at the same time and collide —
  # AWS doesn't make a permission change visible everywhere instantly.
  # If that happens, the fix is a retry step in
  # .github/workflows/terraform-apply.yaml, not something added here.
  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  # Explicit rather than left to modules/vpc's default-name fallback —
  # same names the fallback already produces, just making it intentional.
  # A rename later is a tag update, not a replacement.
  private_subnet_names = [for az in var.azs : "production-Twg-private-sub-${az}"]

  enable_nat_gateway = false
  tgw_id             = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  tags = var.tags
}

# This connects the VPC to the TGW. It gets approved automatically —
# the TGW is set to auto-accept connections, and since this account and
# network are in the same AWS Organization with sharing turned on, there's
# no manual accept step needed.
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
resource "aws_ec2_transit_gateway_route_table_association" "tgw_rtb_association" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  count = var.networking_enabled ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.prod_spoke_route_table_id.value)
}

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
resource "aws_route" "private_to_tgw" {
  # Comes out empty when disabled — module.vpc doesn't exist then, so
  # there's nothing to route from anyway.
  for_each = var.networking_enabled ? { for idx, az in var.azs : az => idx } : {}

  # Safe to reference module.vpc[0]/module.tgw_attachment[0] here: this
  # whole resource is empty exactly when networking is off, so it never
  # actually tries to look at either one when they don't exist.
  route_table_id         = module.vpc[0].private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  depends_on = [module.tgw_attachment]

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
module "prod_purpose_subnets" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/prod-purpose-subnets"

  vpc_id = module.vpc[0].vpc_id
  tgw_id = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

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

  # Same reasoning as aws_route.private_to_tgw above: a route to the TGW
  # only works once the connection actually exists.
  depends_on = [module.tgw_attachment]
}

# These two blocks record a rename from an older branch. Without them,
# Terraform would think the renamed module/resource is something brand
# new, and plan to destroy the existing production subnets, route
# tables, and associations, then recreate them from scratch — a real
# outage, not a harmless rename. Safe to delete once this has actually
# been applied and the state file has caught up (see commit 2495070 for
# an earlier example of the same thing).
moved {
  from = module.purpose_subnets
  to   = module.prod_purpose_subnets
}

moved {
  from = aws_ec2_transit_gateway_route_table_association.this
  to   = aws_ec2_transit_gateway_route_table_association.tgw_rtb_association
}
