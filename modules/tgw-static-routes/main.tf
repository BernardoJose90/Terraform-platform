resource "aws_ec2_transit_gateway_route" "tgw_route" {
  for_each = var.routes

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.key
  transit_gateway_attachment_id  = each.value
}

# This is needed because a spoke's only route is a catch-all 0.0.0.0/0 to
# the egress attachment — nothing more specific than that. Without this
# blackhole route, traffic to the other spoke's CIDR would still match
# that catch-all, go out to the egress VPC, get NAT'd, and then the
# return-path route would deliver it straight to the other spoke — even
# though neither spoke's table ever had a direct route to the other.
resource "aws_ec2_transit_gateway_route" "blackhole_route" {
  for_each = toset(var.blackhole_cidrs)

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.value
  blackhole                      = true
}

# These resources used to be named "this" and "blackhole", renamed to
# "tgw_route" and "blackhole_route". Without these moved blocks, Terraform
# would treat the rename as destroy-old/create-new, tearing down and
# rebuilding every static route in both spoke route tables. The for_each
# keys didn't change, so each existing instance maps across automatically.
moved {
  from = aws_ec2_transit_gateway_route.this
  to   = aws_ec2_transit_gateway_route.tgw_route
}

moved {
  from = aws_ec2_transit_gateway_route.blackhole
  to   = aws_ec2_transit_gateway_route.blackhole_route
}
