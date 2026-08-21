# Runs in a spoke account. Assumes the TGW has already been shared to this
# account through RAM (done by modules/tgw in the network account), and
# that the share invitation has already been accepted — either by hand,
# once, or automatically via aws_ram_resource_share_accepter if that's
# preferred.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  # var.name is used exactly as given for the Name tag (e.g.
  # "tgw-attach-Egress-vpc") — nothing gets appended to it, so whoever
  # calls this module has full control over the exact name.
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



