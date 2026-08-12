output "subnet_ids" {
  description = "Subnet ID keyed by \"<purpose>-<az_key>\", e.g. subnet_ids[\"eks-a\"]. Matches the keys used in var.purposes[*].subnets."
  value       = { for k, s in aws_subnet.prod_workload_sub : k => s.id }
}

output "route_table_ids" {
  description = "Route table ID keyed by purpose, e.g. route_table_ids[\"rds\"]."
  value       = { for k, rt in aws_route_table.prod_workload_rtb : k => rt.id }
}
