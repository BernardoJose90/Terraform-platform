# Runs in a SPOKE account. Assumes the TGW has already been shared to this
# account via RAM (done by modules/tgw in the network account) and the
# share invitation has been accepted — either manually once, or via
# aws_ram_resource_share_accepter here if you prefer it fully automated.
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-tgw-attachment" })

  lifecycle {
    # If AWS marks it as failed, recreate it instead of trying to modify
    # a failed resource. Prevent Terraform from trying to "fix" a failed
    # resource — avoids perpetual diff loops.
    create_before_destroy = true

    ignore_changes = [
      # Don't try to change these after creation — AWS manages these
      # internally.
      security_group_referencing_support,
      appliance_mode_support
    ]
  }
}

# Associate this attachment with the correct TGW route table for its role
# (prod_spoke / dev_spoke / firewall_forwarding — passed in by the caller).
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.tgw_route_table_id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  count = var.enable_propagation ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.tgw_route_table_id
}