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

# The network account needs this to add return routes (spoke CIDR -> TGW)
# to the egress VPC's public route tables, so traffic coming back through
# the NAT gateways can actually find its way to the spokes. Without it,
# the NAT gateway has no route to 10.20.0.0/16 or 10.30.0.0/16, and return
# traffic just gets silently dropped.
#
# This is a list, not a single ID. The upstream module usually only
# creates one shared public route table, so it'll usually have one
# element — but don't assume that, iterate over it instead.
output "public_route_table_ids" {
  description = "Public route table IDs. Usually a single shared table. Empty for spoke VPCs, which have no public subnets."
  value       = module.vpc.public_route_table_ids
}

# This module can only pass NAT gateways one flat tags map
# (nat_gateway_tags), so giving each one a different Name per AZ isn't
# possible through a variable. This output exists so a caller that wants
# that (e.g. "nat-egress-a" vs "nat-egress-b") can rename each one
# individually afterwards, using aws_ec2_tag.
output "natgw_ids" {
  description = "NAT Gateway IDs, one per AZ, same order as var.azs. Empty for spoke VPCs (enable_nat_gateway = false)."
  value       = module.vpc.natgw_ids
}

# ======================================================================================
# VPC Flow Logs. Null when enable_flow_log = false.
# ======================================================================================
output "flow_log_id" {
  description = "ID of the VPC Flow Log resource."
  value       = module.vpc.vpc_flow_log_id
}

output "flow_log_cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group flow logs are delivered to."
  value       = module.vpc.vpc_flow_log_destination_arn
}

output "flow_log_cloudwatch_iam_role_arn" {
  description = "ARN of the IAM role used to deliver flow logs to CloudWatch."
  value       = module.vpc.vpc_flow_log_cloudwatch_iam_role_arn
}

output "flow_log_kms_key_arn" {
  description = "ARN of the CMK encrypting the flow log CloudWatch log group. Null when enable_flow_log = false."
  value       = try(aws_kms_key.flow_log[0].arn, null)
}
