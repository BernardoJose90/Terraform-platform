output "tgw_id" {
  description = "Transit Gateway ID — consumed by production/development via terraform_remote_state"
  value       = module.tgw.tgw_id
}

output "tgw_route_table_ids" {
  description = "Map of TGW route table IDs (main, firewall_forwarding, prod_spoke, dev_spoke)"
  value       = module.tgw.tgw_route_table_ids
}

output "ram_resource_share_arn" {
  description = "RAM resource share ARN — consumed by production/development to auto-accept the TGW share"
  value       = module.tgw.ram_resource_share_arn
}

output "egress_vpc_id" {
  value = module.egress_vpc.vpc_id
}

output "egress_vpc_cidr" {
  value = module.egress_vpc.vpc_cidr
}

output "network_firewall_arn" {
  value = module.network_firewall.firewall_arn
}
