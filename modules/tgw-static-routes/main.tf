resource "aws_ec2_transit_gateway_route" "this" {
  for_each = var.routes

  transit_gateway_route_table_id = var.tgw_route_table_id
  destination_cidr_block          = each.key
  transit_gateway_attachment_id  = each.value
}