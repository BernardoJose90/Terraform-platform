
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

# The values event-network-hub's Helm chart needs (Platform-Gitops,
# apps/event-network-hub/envs/development/values.yaml). Not secrets: the
# password itself stays in Secrets Manager, and the app reads it there.
output "event_network_hub_db_host" {
  description = "event-network-hub's RDS hostname — the chart's database.host. Null when networking_enabled = false or eks_enabled = false."
  value       = one(module.rds_event_network_hub[*].db_instance_address)
}

output "event_network_hub_db_secret_arn" {
  description = "ARN of the RDS-managed master password secret — the chart's database.secretArn. Null when networking_enabled = false or eks_enabled = false."
  value       = one(module.rds_event_network_hub[*].master_user_secret_arn)
}

output "event_network_hub_bucket" {
  description = "event-network-hub's S3 bucket name — the chart's storage.bucket. Null when networking_enabled = false or eks_enabled = false."
  value       = one(module.s3_event_network_hub[*].bucket_id)
}
