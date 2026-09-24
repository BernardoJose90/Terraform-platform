# ======================================================================================
# modules/eks/outputs.tf
#
# This is the module's public interface, consumed by whichever account
# calls it. Renaming or removing anything here is a breaking change for
# the callers.
# ======================================================================================

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint for the cluster's Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster, needed to configure a kubeconfig."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "ID of the cluster's primary security group, created by the EKS service itself."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "ID of the shared security group attached to every managed node group."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, for workloads that need IRSA instead of Pod Identity (e.g. an add-on that doesn't yet support Pod Identity)."
  value       = module.eks.oidc_provider_arn
}

output "cluster_iam_role_arn" {
  description = "ARN of the cluster's own IAM role (trusted by eks.amazonaws.com)."
  value       = module.eks.cluster_iam_role_arn
}

output "eks_managed_node_groups" {
  description = "Full outputs of every managed node group created, keyed the same way as var.node_groups. Includes each group's own IAM role ARN, e.g. for adding it to other resources' access policies."
  value       = module.eks.eks_managed_node_groups
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting Kubernetes Secrets at rest."
  value       = module.eks.kms_key_arn
}

output "cloudwatch_log_group_name" {
  description = "Name of the control-plane CloudWatch log group (all 5 log types)."
  value       = module.eks.cloudwatch_log_group_name
}

output "vpc_cni_pod_identity_role_arn" {
  description = "ARN of the IAM role Pod Identity grants to the VPC CNI's aws-node DaemonSet."
  value       = module.vpc_cni_pod_identity.iam_role_arn
}
