output "subnet_ids" {
  description = "Subnet ID keyed by \"<workload>-<az_key>\", e.g. subnet_ids[\"eks-a\"]. Combines each workload key in var.development_workload_subnets with its per-Availability-Zone (AZ) subnets map key."
  value       = { for k, s in aws_subnet.dev_workload_sub : k => s.id }
}

output "route_table_ids" {
  description = "Route table ID keyed by workload, e.g. route_table_ids[\"rds\"]. One entry per top-level key in var.development_workload_subnets."
  value       = { for k, rt in aws_route_table.dev_workload_rtb : k => rt.id }
}
