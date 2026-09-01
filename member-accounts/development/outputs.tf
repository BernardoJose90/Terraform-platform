
/* output "tgw_attachment_id" {
  description = "TGW VPC attachment ID for the development spoke. Null when networking_enabled = false."
  value       = one(module.tgw_attachment[*].attachment_id)
}
*/
output "vpc_id" {
  description = "Null when networking_enabled = false."
  value       = one(module.vpc[*].vpc_id)
}

output "vpc_cidr" {
  description = "Null when networking_enabled = false."
  value       = one(module.vpc[*].vpc_cidr)
}
