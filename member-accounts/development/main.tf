###############################################
# Account: Development
# Purpose: hosts development workloads
###############################################

terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Kept in sync with the network and production accounts (see their
      # main.tf files). The lock file already resolves to a 6.x version;
      # this just states that requirement explicitly instead of silently
      # floating on whatever ">= 5.83.0" happens to resolve to.
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"
    key          = "development/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
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


data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# Needed to build the Transit Gateway (TGW) spoke-wiring role's ARN (Amazon Resource Name) below.
data "aws_ssm_parameter" "network_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/network"
}

# The main provider for the development account itself — no assumed role needed since Terraform runs directly as this account.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.development_account_id.value]

}

# Assumes an IAM role in the network account that's locked down to just
# this account's own route table plus the shared "main" route table (see
# modules/tgw-spoke-wiring-role). This means development can never touch
# production's route table. See member-accounts/network/main.tf for the
# other half of this setup.
#
# The role is only assumed while this account is wired into the Transit
# Gateway (TGW). When detached (local.tgw_wiring = false), this provider
# just falls back to using this account's own credentials, and nothing
# ever actually uses it. That's what lets an isolated development VPC run
# with no dependency on the network account at all, without every plan
# trying to assume a cross-account role it doesn't need.
provider "aws" {
  alias  = "network"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = local.tgw_wiring ? [1] : []
    content {
      role_arn = "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringDevelopment"
    }
  }
}

# Transit Gateway (TGW) details published by the network account. These
# are only read when this account is actually wired into the TGW
# (local.tgw_wiring) — a standalone, isolated Virtual Private Cloud (VPC)
# has no need for any of it and shouldn't depend on the network account
# being up.
data "aws_ssm_parameter" "tgw_id" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/id"
}

data "aws_ssm_parameter" "dev_spoke_route_table_id" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/dev_spoke"
}

# "main" is the one shared route table that this account and production
# both have write access to. It's used only so each account can publish
# its own return route there — never to reach into the other account's
# own route table.
data "aws_ssm_parameter" "main_route_table_id" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/route_table_ids/main"
}

locals {
  # The VPC (controlled by var.networking_enabled) and the Transit
  # Gateway (TGW) attachment (controlled by var.tgw_attachment_enabled)
  # are turned on and off separately, so development can run as a
  # standalone, isolated VPC with no dependency on the network account.
  # Everything in this file that talks to the network account is
  # controlled by this one flag.
  tgw_wiring = var.networking_enabled && var.tgw_attachment_enabled

  # Defined once here and referenced by both modules below, so the two
  # can never silently drift apart the way two separately hand-typed
  # copies could. This is deliberately always calculated, even when TGW
  # wiring is off: it only reads the network account's ID from the
  # management account (via the aws.management provider), not anything
  # from the TGW itself. Making it conditional would change
  # TerraformDeploy's permissions boundary, which is a separate, more
  # involved change to make on its own.
  extra_assumable_role_arns = [
    "arn:aws:iam::${nonsensitive(data.aws_ssm_parameter.network_account_id.value)}:role/TgwSpokeWiringDevelopment",
  ]
}

module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "development"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "development"
  role_name             = "TerraformDeploy"

  # See production/main.tf's comment on its own permissions boundary for
  # the full reasoning. This account's infrastructure shape (module.vpc,
  # module.tgw_attachment below) is the same as production's, minus the
  # subnets used only for production-specific purposes.
  enable_vpc_networking = true

  extra_assumable_role_arns = local.extra_assumable_role_arns
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "development"


  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"


  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "development"
  role_name             = "TerraformDeploy"

  extra_assumable_role_arns = local.extra_assumable_role_arns

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}

# ============================================================
# THE DEVELOPMENT VIRTUAL PRIVATE CLOUD (VPC) — private subnets only, no
# public ones. When wired to the Transit Gateway (TGW)
# (tgw_attachment_enabled = true), outbound traffic leaves through the
# network account, using the catch-all route added further down in this
# file. When detached, this is a fully isolated VPC: no Network Address
# Translation (NAT), no Internet Gateway (IGW), and no default route to
# anywhere at all.
# ============================================================
module "vpc" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/vpc"

  # Creating this VPC and setting up module.github-oidc-roles (this
  # account's CI/CD permissions) can sometimes happen at the same time
  # and conflict, because AWS doesn't make permission changes visible
  # everywhere instantly. If that happens, the fix is to add a retry step
  # in .github/workflows/terraform-apply.yaml — not to change anything
  # here.
  name = "development-vpc"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets

  enable_nat_gateway = false
  # Only set to a real value while wired into the Transit Gateway (TGW);
  # null when detached. This pairs with allow_no_default_route below so
  # the shared vpc module permits a VPC with no default route out.
  tgw_id                 = local.tgw_wiring ? nonsensitive(data.aws_ssm_parameter.tgw_id[0].value) : null
  allow_no_default_route = !local.tgw_wiring

  tags = var.tags
}

# This account and the network account are in the same AWS Organization,
# with resource sharing turned on. That means the Transit Gateway (TGW)
# connection gets approved automatically — there's no separate manual
# invitation/acceptance step needed.
module "tgw_attachment" {
  count = local.tgw_wiring ? 1 : 0

  source = "../../modules/tgw-attachment"

  name = "dev-spoke"
  # local.tgw_wiring being true always implies var.networking_enabled is
  # also true, so module.vpc[0] definitely exists whenever this module
  # does — it's safe to reference module.vpc[0] below.
  tgw_id     = nonsensitive(data.aws_ssm_parameter.tgw_id[0].value)
  vpc_id     = module.vpc[0].vpc_id
  subnet_ids = module.vpc[0].private_subnet_ids

  tags = var.tags
}

# ============================================================
# Wires this VPC into the Transit Gateway (TGW)'s routing. These
# resources run against the network account, using the scoped-down role
# set up above. They only touch this account's own route table
# (dev_spoke) — there is no direct path between development and
# production traffic.
#
# The route is also "propagated" (announced as a usable route) into
# dev_spoke itself, which the connection needs in order to work at all,
# and into "main", so that return traffic coming back through NAT can
# find its way back here.
# ============================================================
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  count = local.tgw_wiring ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.dev_spoke_route_table_id[0].value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  count = local.tgw_wiring ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.dev_spoke_route_table_id[0].value)
}

resource "aws_ec2_transit_gateway_route_table_propagation" "main" {
  count = local.tgw_wiring ? 1 : 0

  provider = aws.network

  transit_gateway_attachment_id  = module.tgw_attachment[0].attachment_id
  transit_gateway_route_table_id = nonsensitive(data.aws_ssm_parameter.main_route_table_id[0].value)
}

# ============================================================
# Sends outbound traffic from the private subnets to the Transit Gateway
# (TGW). This route has to live here rather than inside the shared vpc
# module: a route can't point at the TGW until the VPC is actually
# connected to it, and that connection is only created AFTER the vpc
# module runs. In other words, the vpc module has no way to wait for a
# connection that doesn't exist yet at the time it runs. The depends_on
# below is the entire reason this route is defined out here instead of
# inside that module.
#
# for_each is built from var.azs (known before anything is created), not
# from the private route table IDs (which are only known after the VPC
# is actually created) — keying off the route table IDs directly would
# fail with a "cannot be determined until apply" error.
# ============================================================

resource "aws_route" "private_to_tgw" {
  # This is empty unless this account is wired into the TGW — an
  # isolated VPC has no default route by design, and module.tgw_attachment
  # doesn't exist in that case either.
  for_each = local.tgw_wiring ? { for idx, az in var.azs : az => idx } : {}

  # It's safe to reference module.vpc[0] and module.tgw_attachment[0]
  # here: this whole resource has no instances exactly when TGW wiring is
  # off, so these lines never actually run when either one doesn't
  # exist.
  route_table_id         = module.vpc[0].private_route_table_ids[each.value]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = nonsensitive(data.aws_ssm_parameter.tgw_id[0].value)

  depends_on = [module.tgw_attachment]

  lifecycle {
    precondition {
      condition     = length(module.vpc[0].private_route_table_ids) == length(var.azs)
      error_message = "Expected one private route table per AZ, got ${length(module.vpc[0].private_route_table_ids)} tables for ${length(var.azs)} AZs."
    }
  }
}

# ============================================================
# Subnets for development's own application: EKS (Kubernetes), RDS
# (database), an internal ALB (load balancer), and a general-purpose
# tier. Mirrors modules/prod-purpose-subnets' shape (see production's
# main.tf) so the two accounts stay structurally in sync, but kept as
# its own module rather than shared code — same reasoning as prod's:
# the network account doesn't need to know how either account's
# application is laid out internally.
#
# Only eks and resources get a route out to the TGW, and only while this
# account is actually wired into it (local.tgw_wiring) — same as the
# rest of this file's egress, an isolated dev VPC has no route out for
# these subnets either. rds and alb never get one: neither a database
# nor an internal load balancer should ever start outbound connections
# on its own.
# ============================================================
module "dev_purpose_subnets" {
  count = var.networking_enabled ? 1 : 0

  source = "../../modules/dev-purpose-subnets"
  vpc_id = module.vpc[0].vpc_id

  # Only a real value while wired into the TGW — null (and every to_tgw
  # below false) when running as a standalone, isolated VPC. Pairs with
  # local.tgw_wiring the same way module.vpc's tgw_id does above.
  tgw_id = local.tgw_wiring ? nonsensitive(data.aws_ssm_parameter.tgw_id[0].value) : null

  development_workload_subnets = {
    eks = {
      route_table_name = "dev-eks-rtb"
      to_tgw           = local.tgw_wiring
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.30.16.0/22", name = "dev-eks-a" }
        b = { az = "eu-west-2b", cidr = "10.30.32.0/22", name = "dev-eks-b" }
      }
    }
    rds = {
      route_table_name = "dev-rds-rtb"
      to_tgw           = false
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.30.50.0/24", name = "dev-rds-a" }
        b = { az = "eu-west-2b", cidr = "10.30.60.0/24", name = "dev-rds-b" }
      }
    }
    alb = {
      route_table_name = "dev-private-alb-rtb"
      to_tgw           = false
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.30.70.0/24", name = "dev-alb-a" }
        b = { az = "eu-west-2b", cidr = "10.30.80.0/24", name = "dev-alb-b" }
      }
    }
    resources = {
      route_table_name = "dev-private-resources-rtb"
      to_tgw           = local.tgw_wiring
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.30.100.0/24", name = "dev-private-resources" }
      }
    }
  }

  tags = var.tags

  # As with aws_route.private_to_tgw above, this module's own to_tgw
  # routes can't target the TGW until the attachment exists.
  depends_on = [module.tgw_attachment]
}

# ============================================================
# Gated on var.eks_enabled as well as var.networking_enabled, so the
# cluster specifically can be paused (e.g. outside working hours) without
# tearing down the VPC and dev_purpose_subnets underneath it.
#
# ORDERING: anything added later that depends on this cluster existing
# (an ALB controller, Argo CD, more Pod Identity associations) must be
# gated the same way (var.networking_enabled && var.eks_enabled), or
# reference it through a count/for_each-safe accessor (e.g.
# one(module.eks[*].cluster_name)) instead of module.eks[0] directly —
# otherwise turning eks_enabled off breaks that resource's plan instead
# of cleanly deleting it.
#
# See modules/eks/main.tf for what's fixed (KMS-encrypted secrets, full
# control-plane logging, access entries instead of aws-auth, IMDSv2,
# encrypted node volumes, CNI permissions via a dedicated Pod Identity
# role) versus what's account-specific here.
# ============================================================
# The IAM role IAM Identity Center provisions in this account for the
# "administrators" SSO permission set (see sso.tf's administrators_admin
# assignment, which already targets this account). Looked up by name
# instead of hardcoded — the role's ARN has an AWS-generated suffix this
# repo doesn't control, and would break if the permission set were ever
# recreated.
data "aws_iam_roles" "sso_admin" {
  name_regex  = "AWSReservedSSO_AdministratorAccess_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

module "eks" {
  count = var.networking_enabled && var.eks_enabled ? 1 : 0

  source = "../../modules/eks"

  name               = "Dev-EKS"
  kubernetes_version = "1.35"

  vpc_id = module.vpc[0].vpc_id
  subnet_ids = [
    module.dev_purpose_subnets[0].subnet_ids["eks-a"],
    module.dev_purpose_subnets[0].subnet_ids["eks-b"],
  ]

  # Public access, restricted to var.eks_endpoint_public_access_cidrs,
  # stays on as an interim state until Argo CD and break-glass access
  # exist — see that variable's own description, and
  # modules/eks/variables.tf, for the reasoning.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  # Grants james.admin (the SSO "administrators" group, already assigned
  # AdministratorAccess on this account via member-accounts/security/sso.tf)
  # cluster-admin Kubernetes RBAC access too. AWS account access and
  # in-cluster Kubernetes access are separate gates under
  # authentication_mode = "API" — the SSO assignment alone doesn't imply
  # this, an access entry is required on top of it. Looked up by name
  # instead of hardcoded, since IAM Identity Center provisions this role's
  # ARN per-account with a random suffix Terraform doesn't control.
  access_entries = {
    james_admin = {
      principal_arn = tolist(data.aws_iam_roles.sso_admin.arns)[0]

      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Matches the console-built cluster's sizing (2 nodes across 2 AZs),
  # with a little autoscaling headroom added on top. Adjust instance
  # size/count here as dev's actual workload needs become clearer.
  node_groups = {
    general = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }
  }

  tags = var.tags
}
