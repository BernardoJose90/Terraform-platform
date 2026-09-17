
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
