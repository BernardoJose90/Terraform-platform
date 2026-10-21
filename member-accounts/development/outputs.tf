
/* output "tgw_attachment_id" {
  description = "The Transit Gateway (TGW) VPC attachment ID for the development spoke. Null (empty) when networking_enabled = false."
  value       = one(module.tgw_attachment[*].attachment_id)
}
*/
output "vpc_id" {
  description = "The development VPC's ID. Null (empty) when networking_enabled = false."
  value       = one(module.vpc[*].vpc_id)
}

output "vpc_cidr" {
  description = "The development VPC's IP address range (CIDR block). Null (empty) when networking_enabled = false."
  value       = one(module.vpc[*].vpc_cidr)
}

output "eks_cluster_name" {
  description = "The development EKS cluster's name. Null (empty) when networking_enabled = false or eks_enabled = false."
  value       = one(module.eks[*].cluster_name)
}

output "eks_cluster_endpoint" {
  description = "The development EKS cluster's Kubernetes API endpoint. Null (empty) when networking_enabled = false or eks_enabled = false."
  value       = one(module.eks[*].cluster_endpoint)
}

output "karpenter_node_iam_role_name" {
  description = "Name of the IAM role for nodes Karpenter itself launches — the EC2NodeClass spec.role value. Null unless enable_karpenter = true on module.eks."
  value       = one(module.eks[*].karpenter_node_iam_role_name)
}

output "karpenter_queue_name" {
  description = "Name of Karpenter's SQS interruption queue — the Helm chart's settings.interruptionQueue value. Null unless enable_karpenter = true on module.eks."
  value       = one(module.eks[*].karpenter_queue_name)
}
