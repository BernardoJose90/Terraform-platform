##########################################
# Account: Development
# Purpose: hosts development workloads
##########################################

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

# Fails the plan early, with a clear message, if this account is set to
# attach but the network account's TGW has been torn down. The tgw_id
# parameter above still holds the last real (now stale) ID in that case,
# so without this check the plan would fail later with a confusing
# "couldn't find resource" error on the attachment.
data "aws_ssm_parameter" "tgw_status" {
  count    = local.tgw_wiring ? 1 : 0
  provider = aws.network
  name     = "/transit-gateway/status"

  lifecycle {
    postcondition {
      condition     = nonsensitive(self.value) == "active"
      error_message = "tgw_attachment_enabled = true, but the network account's Transit Gateway is torn down (/transit-gateway/status is not \"active\"). Set tgw_attachment_enabled = false in terraform.tfvars, or set networking_enabled = true in member-accounts/network/teardown.auto.tfvars and apply the network account first."
    }
  }
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

  # Shared by module.eks's name and the eks subnets' karpenter.sh/discovery
  # tag — Karpenter only finds subnets whose tag value matches the cluster
  # name, so the two must never drift apart. A plain local rather than
  # module.eks[0].cluster_name, since module.eks itself depends on those
  # subnets.
  eks_cluster_name = "Dev-EKS"
}

module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "development"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "development"
  role_name             = "TerraformDeploy"

  # This account runs module.vpc and module.tgw_attachment below — same
  # infrastructure shape as production's own enable_vpc_networking
  # (see its main.tf), minus the subnets used only for
  # production-specific purposes.
  enable_vpc_networking = true

  # This account is the only one running module.eks today.
  enable_eks = true

  # module.s3_event_network_hub below.
  enable_s3 = true

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
  # in .github/workflows/deploy-apply.yaml — not to change anything
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

  # Check the TGW is actually up (see data.aws_ssm_parameter.tgw_status)
  # before touching the attachment, so a torn-down TGW fails with that
  # check's clear message rather than a "couldn't find resource" error.
  depends_on = [data.aws_ssm_parameter.tgw_status]
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
resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
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
      # How Karpenter's EC2NodeClass finds which subnets it may launch nodes
      # into. Must match module.eks's name — the security-group half of this
      # tag is set inside modules/eks (see enable_karpenter there).
      extra_tags = { "karpenter.sh/discovery" = local.eks_cluster_name }
      subnets = {
        a = { az = "eu-west-2a", cidr = "10.30.16.0/22", name = "dev-eks-a" }
        b = { az = "eu-west-2b", cidr = "10.30.32.0/22", name = "dev-eks-b" }
        c = { az = "eu-west-2c", cidr = "10.30.64.0/22", name = "dev-eks-c" }

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
      # How the AWS Load Balancer Controller auto-discovers which subnets it
      # may place internal ALBs/NLBs into. This VPC has no public subnets
      # (see this file's header), so there's no kubernetes.io/role/elb
      # counterpart to set anywhere.
      extra_tags = { "kubernetes.io/role/internal-elb" = "1" }
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

# Same lookup trick as sso_admin above, for the platform-admins group's
# EKS-Admin permission set (member-accounts/security/sso.tf) — narrower
# than full AdministratorAccess, scoped to just EKS access.
data "aws_iam_roles" "sso_eks_admin" {
  name_regex  = "AWSReservedSSO_EKS-Admin_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
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
# See modules/eks/main.tf's own header for what's fixed vs. exposed there.
# ============================================================
module "eks" {
  count = var.networking_enabled && var.eks_enabled ? 1 : 0

  source = "../../modules/eks"

  name               = local.eks_cluster_name
  kubernetes_version = "1.35"

  # TEMPORARY, bootstrap-only. On a fresh (or freshly recreated) cluster,
  # module.vpc_cni_pod_identity can't be created until the node group
  # goes healthy, but the node group can't go healthy without aws-node
  # already having credentials — a confirmed, unfixable-via-Terraform-
  # ordering deadlock in the upstream module (see
  # modules/eks/variables.tf's bootstrap_cni_via_node_role description,
  # and https://github.com/terraform-aws-modules/terraform-aws-eks/issues/3260).
  # Setting this true attaches AmazonEKS_CNI_Policy directly to the node
  # role for one apply, breaking the deadlock. Once the node group and
  # the Pod Identity association are both confirmed healthy, set this
  # back to false and re-apply — do not leave it true long-term.
  bootstrap_cni_via_node_role = false

  vpc_id = module.vpc[0].vpc_id
  subnet_ids = [
    module.dev_purpose_subnets[0].subnet_ids["eks-a"],
    module.dev_purpose_subnets[0].subnet_ids["eks-b"],
    module.dev_purpose_subnets[0].subnet_ids["eks-c"]
  ]

  # Public access, restricted to var.eks_endpoint_public_access_cidrs,
  # stays on as an interim state until Argo CD and break-glass access
  # exist — see that variable's own description, and
  # modules/eks/variables.tf, for the reasoning.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  # Supersedes the old enable_cluster_autoscaler — see modules/eks/variables.tf.
  enable_karpenter = true

  enable_aws_load_balancer_controller = true


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

    # platform-admins group's EKS-Admin permission set
    # (member-accounts/security/sso.tf) — same cluster-admin RBAC policy
    # as james_admin above, but reachable via a narrower AWS-side IAM
    # permission set instead of full AdministratorAccess.
    platform_admins = {
      principal_arn = tolist(data.aws_iam_roles.sso_eks_admin.arns)[0]

      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Was left on the module default (true) until now. CI (TerraformDeploy)
  # doesn't need its own standing Kubernetes RBAC access: it only ever
  # talks to this module via the EKS/IAM APIs (no kubernetes/helm provider
  # anywhere in modules/eks), and TerraformDeploy's own IAM policy already
  # has unscoped eks:* — including eks:CreateAccessEntry — so it can create
  # the access_entries above without first holding cluster-admin itself.
  # Turning this off means the only standing cluster-admin paths are the
  # two explicit access_entries above, not "whoever happened to apply."
  enable_cluster_creator_admin_permissions = false

  # Fixed-size system node group: Karpenter (enable_karpenter above)
  # handles elastic app-workload capacity, so these nodes are only for core
  # components that need a stable home — CoreDNS, kube-proxy, the
  # node-monitoring agent, Argo CD, and Karpenter's own controller, which
  # can never manage the node it's running on. Not meant to run application
  # pods.
  #
  # Two nodes rather than one: a t3.medium caps out at 17 pods, which those
  # add-ons alone fill; and with a single node, losing it takes Karpenter
  # down with it, leaving nothing to replace capacity until the node
  # group's ASG recovers. Two spreads Karpenter's and CoreDNS's replicas
  # across AZs.
  #
  # desired_size is only honoured at creation — the upstream module
  # ignores later changes to it (scaling_config[0].desired_size), so
  # resizing an existing group means scaling it with
  # `aws eks update-nodegroup-config` first, then matching it here.
  node_groups = {
    general = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 2
    }
  }

  tags = var.tags
}

# ========================================================================
# Pod Identity for event-network-hub's own app pods — scaffolded now,
# before modules/rds and modules/s3 are actually called for it (see those
# modules' own "wait until the app is running" discussion). Uses
# modules/app-pod-identity rather than hand-writing this, since
# production will need the exact same thing once its own EKS cluster
# exists — this isn't hypothetical reuse, event-network-hub is already
# confirmed to run in both accounts.
#
# The association (which namespace/service account this role is bound
# to) doesn't need RDS/S3 to exist — only the permissions do.
# namespace/service_account assumed to match event-network-hub-gitops's
# own manifests; this is an exact string match against what's actually
# deployed, so double-check those names once that repo's manifests exist.
#
# No permissions attached yet (policy_statements left at its default
# empty list) — this role can currently do nothing. Once modules/rds and
# modules/s3 are wired up for event-network-hub, add here:
#   - secretsmanager:GetSecretValue scoped to
#     module.rds_event_network_hub[0].master_user_secret_arn
#   - s3:GetObject/PutObject/ListBucket scoped to
#     module.s3_event_network_hub[0].bucket_arn (and that ARN + "/*")
# ======================================================================
module "event_network_hub_pod_identity" {
  count = var.networking_enabled && var.eks_enabled ? 1 : 0

  source = "../../modules/app-pod-identity"

  name            = "event-network-hub-app-pod_identity"
  cluster_name    = module.eks[0].cluster_name
  namespace       = "development"
  service_account = "event-network-hub-sa"

  tags = var.tags

  depends_on = [module.eks]
}

module "s3_event_network_hub" {
  count = var.networking_enabled && var.eks_enabled ? 1 : 0

  source = "../../modules/s3"

  bucket_name     = "event-network-hub-development"
  force_destroy   = true
  expiration_days = 2

  tags = var.tags

  depends_on = [module.eks]

}
