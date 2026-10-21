# ======================================================================================
# Shared Pod Identity module for application pods — not a cluster/platform
# concern like modules/eks's own vpc_cni/karpenter/aws_lb_controller
# associations, and not scoped to one specific app either. Any app
# running in any account's EKS cluster that needs its own AWS permissions
# (reading an RDS secret, reading/writing an S3 bucket, etc.) calls this
# once per account it runs in, rather than hand-writing the same
# eks-pod-identity module call again for every app and every environment.
#
# var.policy_statements defaults to empty — a role that can be created
# now, bound to the right service account, before the resources it needs
# to access (an RDS instance, an S3 bucket) exist yet. Add the real
# statements once those are wired up for this app in this account.
# ======================================================================================

module "pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name = var.name

  attach_custom_policy = true
  policy_statements    = var.policy_statements

  associations = {
    main = {
      cluster_name    = var.cluster_name
      namespace       = var.namespace
      service_account = var.service_account
    }
  }

  tags = var.tags
}
