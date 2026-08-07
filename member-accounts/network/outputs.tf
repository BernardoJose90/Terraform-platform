output "tgw_id" {
  description = "Transit Gateway ID — also published to SSM at /transit-gateway/id for spoke accounts"
  value       = module.tgw.tgw_id
}

output "tgw_route_table_ids" {
  description = "Map of TGW route table IDs (main, prod_spoke, dev_spoke) — the main/prod_spoke/dev_spoke IDs are also published to SSM for spoke accounts"
  value       = module.tgw.tgw_route_table_ids
}

output "ram_resource_share_arn" {
  description = "RAM resource share ARN — also published to SSM at /transit-gateway/ram_resource_share_arn"
  value       = module.tgw.ram_resource_share_arn
}

output "egress_vpc_id" {
  value = module.egress_vpc.vpc_id
}

output "egress_vpc_cidr" {
  value = module.egress_vpc.vpc_cidr
}
