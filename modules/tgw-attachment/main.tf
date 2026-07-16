# Runs in a SPOKE account. Assumes the TGW has already been shared to this
# account via RAM (done by modules/tgw in the network account) and the
# share invitation has been accepted — either manually once, or via
# aws_ram_resource_share_accepter here if you prefer it fully automated.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-tgw-attachment" })

  lifecycle {
    # If AWS marks it as failed, recreate it
    # Instead of trying to modify a failed resource
    create_before_destroy = true

    # Prevent Terraform from trying to "fix" a failed resource
    # This avoids perpetual diff loops
    ignore_changes = [
      # Don't try to change these after creation
      # AWS manages these internally
      security_group_referencing_support,
      appliance_mode_support
    ]
  }
}



