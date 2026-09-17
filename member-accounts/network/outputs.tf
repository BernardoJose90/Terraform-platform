output "tgw_id" {
  description = "The Transit Gateway (TGW)'s ID. Also published to AWS Systems Manager (SSM) Parameter Store at /transit-gateway/id for the spoke accounts to read. This is null (empty) when networking_enabled = false — use the SSM parameter's frozen value instead if you need the ID while networking is disabled."
  value       = one(module.tgw[*].tgw_id)
}

output "tgw_route_table_ids" {
  description = "A map of the Transit Gateway (TGW)'s route table IDs (main, prod_spoke, dev_spoke). The main, prod_spoke, and dev_spoke IDs are also published to SSM for the spoke accounts to read. This is null (empty) when networking_enabled = false."
  value       = one(module.tgw[*].tgw_route_table_ids)
}

output "ram_resource_share_arn" {
  description = "The ARN (Amazon Resource Name, AWS's unique identifier format) of the AWS Resource Access Manager (RAM) share that gives the spoke accounts access to the Transit Gateway. Also published to SSM at /transit-gateway/ram_resource_share_arn. This is null (empty) when networking_enabled = false."
  value       = one(module.tgw[*].ram_resource_share_arn)
}

output "egress_vpc_id" {
  description = "The egress VPC's ID. This is null (empty) when networking_enabled = false."
  value       = one(module.egress_vpc[*].vpc_id)
}

output "egress_vpc_cidr" {
  description = "The egress VPC's IP address range (CIDR block). This is null (empty) when networking_enabled = false."
  value       = one(module.egress_vpc[*].vpc_cidr)
}
