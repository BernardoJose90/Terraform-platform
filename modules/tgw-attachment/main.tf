# Runs in a SPOKE account. Assumes the TGW has already been shared to this
# account via RAM (done by modules/tgw in the network account) and the
# share invitation has been accepted — either manually once, or via
# aws_ram_resource_share_accepter here if you prefer it fully automated.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-tgw-attachment" })
}

# Associate this attachment with the network account's TGW route table.
# Requires the network account's TGW route table ID as input — pass it
# via remote state, an SSM parameter, or a hardcoded output from the
# network account's apply.
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.tgw_route_table_id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.tgw_route_table_id
}