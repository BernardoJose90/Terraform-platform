resource "aws_ec2_transit_gateway_route" "tgw_route" {
  for_each = var.routes

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.key
  transit_gateway_attachment_id  = each.value
}

# Needed because a spoke's only route is 0.0.0.0/0 to the egress attachment,
# with nothing more specific. Without this, traffic to the other spoke's CIDR
# still matches that default route, reaches the egress VPC, gets NAT'd, and
# the return-path route delivers it to the other spoke, even though neither
# spoke's table ever contains a direct route to the other.
resource "aws_ec2_transit_gateway_route" "blackhole_route" {
  for_each = toset(var.blackhole_cidrs)

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.value
  blackhole                      = true
}

# Renamed from "this"/"blackhole" to "tgw_route"/"blackhole_route". Without
# these, Terraform sees the renames as destroy-old/create-new instead of an
# in-place move, which would tear down and recreate every static route in
# both spoke route tables. for_each keys are unchanged, so each instance
# maps across automatically.
moved {
  from = aws_ec2_transit_gateway_route.this
  to   = aws_ec2_transit_gateway_route.tgw_route
}

moved {
  from = aws_ec2_transit_gateway_route.blackhole
  to   = aws_ec2_transit_gateway_route.blackhole_route
}
