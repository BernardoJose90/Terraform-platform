# Runs in a SPOKE account. Assumes the TGW has already been shared to this
# account via RAM (done by modules/tgw in the network account) and the
# share invitation has been accepted — either manually once, or via
# aws_ram_resource_share_accepter here if you prefer it fully automated.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  # var.name is the FULL, exact Name tag (e.g. "tgw-attach-Egress-vpc") — no
  # suffix appended, so callers control the exact name end to end.
  tags = merge(var.tags, { Name = var.name })

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



