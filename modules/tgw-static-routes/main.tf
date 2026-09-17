# Creates one Transit Gateway route per entry in var.routes: each entry's
# key is a destination CIDR block (a range of IP addresses), and its
# value is the ID of the attachment that traffic to that range should be
# sent to.
resource "aws_ec2_transit_gateway_route" "tgw_route" {
  for_each = var.routes

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.key
  transit_gateway_attachment_id  = each.value
}

# Why this is needed: a spoke's route table normally has only one route, a
# catch-all "0.0.0.0/0" (meaning "everything") pointing at the shared
# egress attachment — nothing more specific than that. Without this
# "blackhole" route (a route that just drops matching traffic instead of
# sending it anywhere), traffic addressed to another spoke's CIDR block (a
# range of IP addresses) would still match that catch-all route. It would
# be sent out to the egress VPC, get translated by NAT, and then a
# return-path route would deliver it straight to the other spoke — even
# though neither spoke's route table ever had a direct route to the other.
# This blackhole route exists to block that unintended path.
resource "aws_ec2_transit_gateway_route" "blackhole_route" {
  for_each = toset(var.blackhole_cidrs)

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block         = each.value
  blackhole                      = true
}

# These two resources used to be named "this" and "blackhole"; they were
# renamed to "tgw_route" and "blackhole_route" for clarity. The `moved`
# blocks below tell Terraform this was only a rename, not a
# delete-and-recreate. Without them, Terraform would tear down and rebuild
# every static route in both spoke route tables, because it wouldn't know
# that the old and new resource names refer to the same infrastructure.
# The for_each keys (the map/set entries each resource is created from)
# didn't change, so every existing route maps across to its renamed
# resource automatically.
moved {
  from = aws_ec2_transit_gateway_route.this
  to   = aws_ec2_transit_gateway_route.tgw_route
}

moved {
  from = aws_ec2_transit_gateway_route.blackhole
  to   = aws_ec2_transit_gateway_route.blackhole_route
}
