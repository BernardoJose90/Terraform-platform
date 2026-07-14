resource "aws_ec2_transit_gateway" "this" {
  description                    = var.name
  amazon_side_asn                = var.amazon_side_asn
  auto_accept_shared_attachments = "enable" # spokes' attachments auto-accept

  # We manage association/propagation explicitly instead of the "enable"
  # shortcut, so we can later segment traffic (e.g. keep prod isolated
  # from dev) without restructuring later.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags                = merge(var.tags, { Name = "${var.name}-rt" })
}

# Share the TGW to the other accounts in your AWS Organization via RAM.
resource "aws_ram_resource_share" "tgw" {
  name                      = "${var.name}-share"
  allow_external_principals = false

  tags = var.tags
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