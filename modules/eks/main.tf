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
#   - Every managed node group: IMDSv2 required, and an encrypted EBS root
#     volume.
#
# What IS exposed (variables.tf) is what genuinely differs per account:
# cluster name, subnets, node group sizing, how open the public endpoint
# is, and (temporarily, see var.bootstrap_cni_via_node_role below)
# whether the node role carries AmazonEKS_CNI_Policy.
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

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Applied to every managed node group regardless of what the caller
  # passes in var.node_groups — see the header comment for why these
  # aren't variables. block_device_mappings is finished per-group below,
  # once each group's own disk_size is known.
  node_group_defaults = {
    # Normally false — CNI permissions come only from the dedicated Pod
    # Identity role (module.vpc_cni_pod_identity below), never the node
    # role. Temporary exception: on a cluster's very first bootstrap,
    # module.vpc_cni_pod_identity can't be created until module.eks
    # (cluster + addons + node groups) finishes, but node groups can never
    # go healthy without aws-node already having working credentials —
    # neither side can go first. This is a confirmed, unfixable-via-
    # Terraform-ordering limitation of the upstream module, not something
    # this repo's own code can resolve (see
    # https://github.com/terraform-aws-modules/terraform-aws-eks/issues/3260,
    # maintainer bryantbiggs: "deploy the node IAM role with the
    # permissions required by the VPC CNI and then remove those on a
    # subsequent apply"). var.bootstrap_cni_via_node_role breaks the
    # deadlock: set it true for the first apply only, confirm the cluster,
    # nodes, and the Pod Identity association are all healthy, then set it
    # back to false and re-apply to remove the fallback.
    iam_role_attach_cni_policy = var.bootstrap_cni_via_node_role

    metadata_options = {
      http_tokens                 = "required" # IMDSv2 only, no IMDSv1 fallback
      http_put_response_hop_limit = 1
    }

    # Cluster Autoscaler auto-discovers ASGs by these tags (its
    # --node-group-auto-discovery flag), and the Pod Identity policy below
    # only grants SetDesiredCapacity/TerminateInstanceInAutoScalingGroup on
    # ASGs tagged kubernetes.io/cluster/<name>=owned. Without both, the
    # controller either can't find the ASG or can't act on it.
    autoscaling_group_tags = var.enable_cluster_autoscaler ? {
      "k8s.io/cluster-autoscaler/enabled"     = "true"
      "k8s.io/cluster-autoscaler/${var.name}" = "owned"
      "kubernetes.io/cluster/${var.name}"     = "owned"
    } : {}
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

# ======================================================================================
# Dedicated CMK (Customer Master Key) for the control-plane's CloudWatch
# log group. Not the same key as encryption_config's Secrets key below —
# reusing that one here would create a circular reference, since it isn't
# known until module.eks itself is created. Mirrors modules/vpc's
# aws_kms_key.flow_log / aws_kms_alias.flow_log pattern exactly, just
# scoped to this cluster's own control-plane log group instead of a VPC's
# flow logs.
# ======================================================================================
data "aws_iam_policy_document" "cluster_log_kms" {
  statement {
    sid     = "EnableIAMUserPermissions"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    # See modules/vpc's identical statement for why this "*" is safe — a
    # key's own policy can only ever grant permissions on itself, so the
    # actual narrowing happens in the condition below.
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.name}/cluster"]
    }
  }
}

resource "aws_kms_key" "cluster_log" {
  description             = "CMK for ${var.name} EKS control-plane CloudWatch log group"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cluster_log_kms.json

  tags = var.tags
}

resource "aws_kms_alias" "cluster_log" {
  name          = "alias/${var.name}-eks-cluster-log"
  target_key_id = aws_kms_key.cluster_log.key_id
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
  cloudwatch_log_group_kms_key_id        = aws_kms_key.cluster_log.arn

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

# ======================================================================================
# Cluster Autoscaler's IAM side only — the controller itself is deployed
# outside Terraform (see this repo's Argo CD plans, referenced in
# member-accounts/development/main.tf's module "eks" call). This just
# gives the "cluster-autoscaler" service account in kube-system a Pod
# Identity role scoped to this cluster's own ASGs, via
# attach_cluster_autoscaler_policy on the same upstream module used for
# the VPC CNI above — no hand-written IAM policy needed.
#
# Optional (var.enable_cluster_autoscaler) because it's a no-op — an
# unused role and unused ASG tags — until something actually installs the
# controller against that service account.
# ======================================================================================
module "cluster_autoscaler_pod_identity" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name = "${var.name}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [var.name]

  associations = {
    main = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
    }
  }

  tags = var.tags

  depends_on = [module.eks]
}
