# Runs in a spoke account. Assumes the TGW has already been shared to this
# account via RAM (done by modules/tgw in the network account) and the
# share invitation has been accepted, either manually once or via
# aws_ram_resource_share_accepter here if you prefer it fully automated.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  # var.name is the full, exact Name tag (e.g. "tgw-attach-Egress-vpc"), no
  # suffix appended, so callers control the exact name end to end.
  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    # If AWS marks it as failed, recreate it instead of trying to modify
    # a failed resource.
    create_before_destroy = true

    # AWS manages these internally after creation; ignoring them avoids
    # perpetual diff loops.
    ignore_changes = [
      security_group_referencing_support,
      appliance_mode_support
    ]
  }
}



