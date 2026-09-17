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

# The network account needs this output to add "return" routes back to
# each spoke's CIDR (its IP address range) through the Transit Gateway,
# into the egress VPC's public route tables. Those routes are what let
# traffic coming back through the NAT gateways actually find its way back
# to the spoke VPCs. Without them, the NAT gateway has no route to
# 10.20.0.0/16 or 10.30.0.0/16 (the spoke VPCs' CIDR ranges), and return
# traffic is silently dropped.
#
# Note this is a list, not a single ID. The upstream module usually
# creates just one shared public route table, so in practice the list
# will usually have one element — but don't assume that. Loop over it
# instead of indexing the first element directly.
output "public_route_table_ids" {
  description = "Public route table IDs. Usually a single shared table. Empty for spoke VPCs, which have no public subnets."
  value       = module.vpc.public_route_table_ids
}

# This module can only pass one flat map of tags to all NAT gateways at
# once (nat_gateway_tags), so giving each one a different Name tag per
# Availability Zone isn't possible through a variable. This output lets a
# caller that wants that — e.g. naming them "nat-egress-a" vs
# "nat-egress-b" — rename each NAT gateway individually afterwards, using
# the aws_ec2_tag resource.
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
