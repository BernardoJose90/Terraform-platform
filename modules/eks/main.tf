# ======================================================================================
# Shared EKS (Elastic Kubernetes Service) module. Wraps
# terraform-aws-modules/eks/aws the same way modules/vpc wraps
# terraform-aws-modules/vpc/aws: one local module that bakes in this
# platform's own security baseline, so every account that runs a cluster
# gets it automatically instead of having to remember to configure it by
# hand each time.
#
# Baked in here, not exposed as variables, because there's no legitimate
# reason for a caller to turn them off:
#   - KMS envelope encryption of Kubernetes Secrets. This is actually the
#     upstream module's own default (create_kms_key = true whenever
#     encryption_config != null) — we just don't override it away.
#   - All 5 control-plane log types, not just audit+authenticator.
#   - authentication_mode = "API" (EKS access entries, not the aws-auth
#     ConfigMap).
#   - The private endpoint is always reachable, regardless of
#     var.endpoint_public_access — in-VPC callers should never need the
#     internet to reach the API server.
#   - Every managed node group: IMDSv2 required, encrypted EBS root
#     volume, and no AmazonEKS_CNI_Policy on the node role.
#
# What IS exposed (variables.tf) is what genuinely differs per account:
# cluster name, subnets, node group sizing, and how open the public
# endpoint is.
#
# Modeled on the cluster built by hand in the AWS console for the
# development account: same three-role IAM split (cluster role, node
# role, and a separate Pod Identity role scoped to just the VPC CNI's
# aws-node DaemonSet — see module.vpc_cni_pod_identity below), same
# non-Auto-Mode custom node group. member-accounts/development/main.tf
# has a commented-out module "eks" stub using EKS Auto Mode — this module
# deliberately does NOT do that: Auto Mode hands node-level control back
# to AWS and adds its own per-cluster fee, both of which the original
# console setup was built to avoid.
# ======================================================================================

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Applied to every managed node group regardless of what the caller
  # passes in var.node_groups — see the header comment for why these
  # aren't variables. block_device_mappings is finished per-group below,
  # once each group's own disk_size is known.
  node_group_defaults = {
    iam_role_attach_cni_policy = false

    metadata_options = {
      http_tokens                 = "required" # IMDSv2 only, no IMDSv1 fallback
      http_put_response_hop_limit = 2
    }
  }

  eks_managed_node_groups = {
    for name, group in var.node_groups : name => merge(local.node_group_defaults, {
      subnet_ids     = coalesce(group.subnet_ids, var.subnet_ids)
      instance_types = group.instance_types
      capacity_type  = group.capacity_type
      min_size       = group.min_size
      max_size       = group.max_size
      desired_size   = group.desired_size
      labels         = group.labels
      taints         = group.taints

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = group.disk_size
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    })
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # The private endpoint stays on unconditionally (see header comment).
  # Only the public side is caller-controlled.
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # All 5 control-plane log types. The upstream module's own default is
  # only ["audit", "api", "authenticator"] — controllerManager and
  # scheduler are added on top of that here, not left to the default.
  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days

  # EKS access entries instead of the aws-auth ConfigMap — see header
  # comment. enable_cluster_creator_admin_permissions matters in
  # particular for CI: without it, the very first apply has no identity
  # with permission to grant any further access_entries at all.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  encryption_config = { resources = ["secrets"] }

  # before_compute = true for vpc-cni and eks-pod-identity-agent so
  # networking and Pod Identity are both ready before any node tries to
  # join — otherwise the first node group can race the addons that it
  # depends on.
  addons = merge(
    {
      vpc-cni                = { before_compute = true }
      eks-pod-identity-agent = { before_compute = true }
      kube-proxy             = {}
      coredns                = {}
    },
    var.enable_metrics_server ? { metrics-server = {} } : {},
    var.enable_node_monitoring_agent ? { eks-node-monitoring-agent = {} } : {},
  )

  eks_managed_node_groups = local.eks_managed_node_groups

  tags = var.tags
}

# ======================================================================================
# The VPC CNI's aws-node DaemonSet gets its own IAM role via Pod Identity,
# scoped to exactly AmazonEKS_CNI_Policy — never the node role (see
# node_group_defaults.iam_role_attach_cni_policy = false above). Mirrors
# the console-built cluster's dev-eks-vpc-cni-role.
#
# depends_on module.eks because the association needs the
# eks-pod-identity-agent addon to already be installed on the cluster —
# nothing about referencing module.eks.cluster_name on its own guarantees
# that ordering.
# ======================================================================================
module "vpc_cni_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name = "${var.name}-vpc-cni"

  attach_aws_vpc_cni_policy = true
  aws_vpc_cni_enable_ipv4   = true

  associations = {
    main = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-node"
    }
  }

  tags = var.tags

  depends_on = [module.eks]
}
