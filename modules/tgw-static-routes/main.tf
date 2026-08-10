resource "aws_ec2_transit_gateway_route" "this" {
  for_each = var.routes

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.key
  transit_gateway_attachment_id  = each.value
}

# Explicit reject rather than falling through to whatever the default route
# happens to point at. Needed because a spoke's only route is 0.0.0.0/0 to
# the egress attachment — with nothing more specific, traffic to the OTHER
# spoke's CIDR still matches that default route, reaches the egress VPC,
# gets NAT'd, and the return-path route delivers it to the other spoke. The
# spoke route tables never contain a route to each other, but the traffic
# still gets there — an accidental side effect of 0.0.0.0/0 being a superset
# of every other CIDR, not anything either spoke table explicitly allows.
#
# Longest-prefix-match means a blackhole for the specific opposing CIDR
# always wins over the broader 0.0.0.0/0 default, so this is caught at the
# TGW itself, before the packet ever reaches the egress VPC.
resource "aws_ec2_transit_gateway_route" "blackhole" {
  for_each = toset(var.blackhole_cidrs)

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.value
  blackhole                      = true
}
