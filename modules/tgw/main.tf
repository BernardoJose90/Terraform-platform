resource "aws_ec2_transit_gateway" "this" {
  description                    = var.name
  amazon_side_asn                = var.amazon_side_asn
  auto_accept_shared_attachments = "enable" # spokes' attachments auto-accept

  # We manage association/propagation explicitly instead of the "enable"
  # shortcut, so we can segment traffic (prod isolated from dev, everything
  # forced through the firewall attachment) without restructuring later.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  tags = merge(var.tags, { Name = var.name })
}

# Post-inspection router. Associated with tgw-attach-firewall. Receives
# traffic after Network Firewall has inspected it and forwards it on to
# its real destination (a spoke VPC or the egress VPC).
resource "aws_ec2_transit_gateway_route_table" "firewall_forwarding" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags                = merge(var.tags, { Name = "${var.name}-firewall-forwarding-rt" })
}

# Associated with tgw-attach-prod-spoke. Everything (0.0.0.0/0 and all
# cross-VPC CIDRs) defaults to the firewall attachment; only prod's own
# CIDR propagates in automatically.
resource "aws_ec2_transit_gateway_route_table" "prod_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags                = merge(var.tags, { Name = "${var.name}-prod-spoke-rt" })
}

# Same idea for dev.
resource "aws_ec2_transit_gateway_route_table" "dev_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags                = merge(var.tags, { Name = "${var.name}-dev-spoke-rt" })
}

# Share the TGW to the other accounts in your AWS Organization via RAM.
resource "aws_ram_resource_share" "tgw" {
  name                      = "${var.name}-share"
  allow_external_principals = false
  tags                      = var.tags
}

resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.this.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

resource "aws_ram_principal_association" "tgw" {
  for_each = toset(var.share_with_principals)

  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw.arn
}