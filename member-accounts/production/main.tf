#########################################################################################################
# Account: Production
#
# Runs the live application - EKS (managed Kubernetes), RDS (managed
# database), and an internal ALB (load balancer). This VPC (Virtual
# Private Cloud - an isolated network) is private only: it has no
# internet gateway or NAT gateway of its own. All outbound traffic
# instead leaves through the network account's setup, over the Transit
# Gateway (TGW), which is AWS's hub for connecting multiple VPCs and
# accounts together.
#
# To reach the network account, this account assumes a role
# (TgwSpokeWiringProduction) that is only allowed to touch its own route
# table, plus one shared "main" table. It can never touch development's
# route table. Details about the Transit Gateway come from SSM (Systems
# Manager) parameters that the network account publishes, not from
# reading the network account's Terraform state directly.
#
# Everything in this file can be switched off with var.networking_enabled.
##########################################################################################################

terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"

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

# Provider for reading SSM from the management account (cross-account role).
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

# Used below to build the ARN (Amazon Resource Name - AWS's unique ID
# format for a resource) of the TGW spoke-wiring role (aws.network
# provider), and for extra_assumable_role_arns.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}


# Main provider for the production account itself, no profile needed.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]
}

# This provider assumes a role in the network account. That role is
# locked down (see modules/tgw-spoke-wiring-role) so it can only touch
# this account's own route table plus the shared "main" table - never
# development's route table. See member-accounts/network/main.tf for
# the matching setup on the network account's side.
provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction"
  }
}

# These are TGW details (IDs, route table IDs) published by the network
# account. They're read using the aws.network role above instead of
# reading the network account's Terraform state file directly, so that
# this account's read-only "plan" role never needs access to that state
# file.
data "aws_ssm_parameter" "tgw_id" {
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "prod_spoke_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/prod_spoke"
}

# "main" is the one route table that both this account and development
# are allowed to write to. It's only used so each account can publish its
# own return route there - not so one account can reach into the other's
# table.
data "aws_ssm_parameter" "main_route_table_id" {
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

# Defined once here and reused by both modules below, so the two can
# never quietly drift out of sync. Changing this list also changes what
# the TerraformDeploy role's permissions boundary allows.
locals {
  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringProduction",
  ]
}

module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "production"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "production"
  role_name             = "TerraformDeploy"

  # This account runs module.vpc, module.tgw_attachment, and
  # module.prod_purpose_subnets below.
  enable_vpc_networking = true

  extra_assumable_role_arns = local.extra_assumable_role_arns
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

  extra_assumable_role_arns = local.extra_assumable_role_arns

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}

# ============================================================
# PRODUCTION VPC - private only. It has no NAT gateway or internet
# gateway of its own, since outbound traffic goes through the network
# account instead. The catch-all route (0.0.0.0/0, meaning "everything
# else") that sends traffic to the TGW is added further down
# (aws_route.private_to_tgw) rather than inside modules/vpc - see that
# block below for why.
# ============================================================
module "vpc" {
  count = var.networking_enabled ? 1 : 0


  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  private_subnet_names = [for az in var.azs : "production-Twg-private-sub-${az}"]

  enable_nat_gateway = false

  # This is only passed in so the module can validate that this VPC has a
  # declared way out to the rest of the network (i.e. it's a "spoke", not
  # an isolated island). The actual outbound route is created separately,
  # in aws_route.private_to_tgw below.
  tgw_id = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  tags = var.tags
}

# This account and the network account are in the same AWS Organization
# with resource sharing turned on, and the TGW is set to auto-accept
# attachments. So this connection gets approved automatically - there's
# no separate invitation step to accept.
module "tgw_attachment" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/tgw-attachment"

  name = "tgw-attach-prod-spoke"
  # This block is switched on/off by the exact same condition as
  # module.vpc above. So whenever this block exists, the VPC definitely
  # exists too, which makes it safe to reference module.vpc[0] below.
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)
  vpc_id     = module.vpc[0].vpc_id
  subnet_ids = module.vpc[0].private_subnet_ids

  tags = var.tags
}

# ============================================================
# This wires the VPC into the TGW's routing. It runs against the network
# account, using the scoped-down role set up above. It's only linked to
# this account's own route table (prod_spoke) - there is no direct path
# between production traffic and development traffic.
#
# The route is also "propagated" (announced as a valid route) into two
# route tables: prod_spoke itself, which the connection needs in order
# to work at all, and "main", so that return traffic can find its way
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
# to live here rather than inside modules/vpc, because a route can't
# point at the TGW until the VPC is actually connected to it - and that
# connection is only created AFTER modules/vpc runs. In other words,
# modules/vpc has no way to wait for something that doesn't exist yet
# at the time it runs. The depends_on below is the whole reason this
# route lives out here instead of inside that module.
# ============================================================

# for_each is built from var.azs, which is known before anything runs.
# It is NOT built from the private route table IDs, because those are
# only known after the VPC is actually created - using them directly
# here would fail with a "cannot be determined until apply" error.
resource "aws_route" "private_to_tgw" {

  for_each = var.networking_enabled ? { for idx, az in var.azs : az => idx } : {}

  route_table_id         = module.vpc[0].private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id.value)

  # A route can't target the TGW until the attachment exists.
  depends_on = [module.tgw_attachment]

  lifecycle {
    precondition {
      condition     = length(module.vpc[0].private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc[0].private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}

# ============================================================
# Subnets for production's own application: EKS (Kubernetes), RDS
# (database), an internal ALB (load balancer), and a general-purpose
# tier. This is kept as its own module rather than folded into
# modules/vpc, because the network and development accounts don't need
# to know anything about how production's application is laid out
# internally.
#
# Only the eks and resources subnet groups get a route out to the TGW.
# rds and alb deliberately don't, because neither a database nor an
# internal load balancer should ever need to start outbound connections
# on its own.
#
# TEARDOWN FLAG: this switches off along with everything else that
# depends on the VPC.
# ============================================================

module "prod_purpose_subnets" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/prod-purpose-subnets"
  vpc_id = module.vpc[0].vpc_id

  # Unlike the tgw_id passed into modules/vpc above (which was only for
  # validation), this one is used for real: this module DOES create the
  # per-workload route to 0.0.0.0/0 via the TGW, for whichever workloads
  # have to_tgw = true (eks and resources, below).
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

  # As with the route above, this module's own to_tgw routes can't
  # target the TGW until the attachment exists.
  depends_on = [module.tgw_attachment]
}
