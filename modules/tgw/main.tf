# Transit Gateway
resource "aws_ec2_transit_gateway" "this" {
  description                     = var.name
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = merge(var.tags, { Name = var.name })
}

# ============================================================
# ROUTE TABLES
# ============================================================
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-rt-main" })
}

resource "aws_ec2_transit_gateway_route_table" "firewall_forwarding" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-rt-firewall-forwarding" })
}

resource "aws_ec2_transit_gateway_route_table" "prod_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-rt-prod-spoke" })
}

resource "aws_ec2_transit_gateway_route_table" "dev_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-rt-dev-spoke" })
}

# ============================================================
# RAM SHARING
# ============================================================
resource "aws_ram_resource_share" "tgw" {
  name                      = "${var.name}-share"
  allow_external_principals = false
  tags                      = var.tags
}

# Share the TGW itself
resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.this.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

# Share principals (prod/dev accounts)
resource "aws_ram_principal_association" "tgw" {
  for_each           = toset(var.share_with_principals)
  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw.arn
}