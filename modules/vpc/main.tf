module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # Only the network account VPC should set these to true.
  # Spoke VPCs stay private-only and route egress(outbound traffic) via the TGW instead.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # Spokes generally have no public subnets / IGW at all — enable_nat_gateway
  # false + an empty public_subnets list gives you a fully private VPC.

  tags = var.tags

}

# Extra "spoke egress(outbound )" route added to every private route table, pointing 0.0.0.0/0 at the Transit Gateway. 
# Only used when var.tgw_id is set — leave null for the network account's NAT VPC, which doesn't need this since it *is* the egress point.
# This ensures all outbound traffic from private subnets in spoke VPCs goes through the TGW to reach network account's VPC for internet egress
resource "aws_route" "private_to_tgw" {
  for_each = var.tgw_id != null ? toset(module.vpc.private_route_table_ids) : []

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id

}
