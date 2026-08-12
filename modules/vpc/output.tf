# ======================================================================================
# modules/vpc/outputs.tf
#
# This is the module's public interface, consumed by all three accounts.
# Renaming or removing anything here is a breaking change for the callers.
# ======================================================================================

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC. Read by the network account via terraform_remote_state to build TGW routes."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs, one per AZ, in the same order as var.azs. Passed to the TGW attachment module."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs. Empty list for spoke VPCs, which have no public subnets — do not index into this without checking length first."
  value       = module.vpc.public_subnets
}

output "private_route_table_ids" {
  description = "Private route table IDs, one per AZ. Exposed so root modules can add their own routes."
  value       = module.vpc.private_route_table_ids
}

# Needed by the network account to add return routes (spoke CIDRs -> TGW) to the
# egress VPC's public route tables, so traffic coming back through the NAT gateways
# can find its way to the spokes. Without this the NAT gateway has no route to
# 10.20.0.0/16 or 10.30.0.0/16 and return traffic is silently dropped.
#
# This is a LIST. The upstream module normally creates a single shared public
# route table, so it usually has one element, but don't assume that; iterate.
output "public_route_table_ids" {
  description = "Public route table IDs. Usually a single shared table. Empty for spoke VPCs, which have no public subnets."
  value       = module.vpc.public_route_table_ids
}

# NAT gateways can only get one flat tags map from this module
# (nat_gateway_tags), so a different Name per AZ isn't possible through a
# variable. Exposed so a caller that needs that (e.g. "nat-egress-a" vs
# "nat-egress-b") can rename each one individually with aws_ec2_tag.
output "natgw_ids" {
  description = "NAT Gateway IDs, one per AZ, same order as var.azs. Empty for spoke VPCs (enable_nat_gateway = false)."
  value       = module.vpc.natgw_ids
}
