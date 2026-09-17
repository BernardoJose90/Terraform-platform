# This module runs inside a "spoke" AWS account (as opposed to the central
# network account). It assumes the Transit Gateway (TGW) — the AWS service
# that connects multiple VPCs (Virtual Private Clouds) together — has
# already been shared with this account. That sharing happens through AWS
# Resource Access Manager (RAM), and is set up by modules/tgw in the
# network account. It also assumes the resulting share invitation has
# already been accepted, either by hand, once, or automatically via
# aws_ram_resource_share_accepter, if that approach is preferred instead.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  # The Name tag is set to var.name exactly as passed in (for example,
  # "tgw-attach-Egress-vpc"). Nothing is appended to it, so whoever calls
  # this module has full control over the final name.
  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    # If AWS marks this attachment as failed, create a new one before
    # destroying the old one, instead of trying to modify a failed
    # resource (which wouldn't work).
    create_before_destroy = true

    # AWS updates these two settings on its own after the attachment is
    # created. If Terraform didn't ignore them, it would keep seeing them
    # as "changed" and trying to set them back, forever (an endless diff).
    ignore_changes = [
      security_group_referencing_support,
      appliance_mode_support
    ]
  }
}
