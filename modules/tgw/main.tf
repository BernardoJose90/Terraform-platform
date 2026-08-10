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
#
# Each spoke gets its own isolated table — prod's automation can only ever
# touch prod_spoke, dev's only dev_spoke (see modules/tgw-spoke-wiring-role).
# Neither propagates into the other's table, so there is no east-west path
# between prod and dev at all; each spoke's table carries only a static
# default route out to the egress attachment for internet access.
#
# "main" is the one table both spokes DO share write access to, but only
# for propagating their own attachment's return route into it — it's
# associated with the egress VPC attachment, so it's consulted for NAT
# return traffic coming back through the egress VPC. This is the same
# shape the original (pre-firewall) design used: a single narrow shared
# surface for the return path, full isolation everywhere else.
# ============================================================
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "tgw-Egress-vpc-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "prod_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "tgw-prod-spoke-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "dev_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "tgw-dev-spoke-rt" })
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