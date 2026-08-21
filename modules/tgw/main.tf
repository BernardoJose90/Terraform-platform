# Transit Gateway
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = var.name
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = merge(var.tags, { Name = var.name })
}

# This resource used to be named "this" and got renamed to "tgw". Without
# this moved block, Terraform would read that rename as "delete the old
# one, create a new one" instead of an in-place rename — which would tear
# down the actual Transit Gateway, and everything attached to it in every
# account, then rebuild it from scratch.
moved {
  from = aws_ec2_transit_gateway.this
  to   = aws_ec2_transit_gateway.tgw
}

# ============================================================
# ROUTE TABLES. Each spoke gets its own table that only its own automation
# can touch — production only touches prod_spoke, development only
# touches dev_spoke (enforced in modules/tgw-spoke-wiring-role) — and
# routes never propagate between them, so there's no direct path between
# the two environments. "main" is the one table both spokes are allowed to
# write to, and only to publish their own return route; it's attached to
# the egress VPC's connection, so that's what NAT return traffic actually
# consults. One narrow shared spot, everything else fully isolated.
# ============================================================
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = merge(var.tags, { Name = "tgw-Egress-vpc-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "prod_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = merge(var.tags, { Name = "tgw-prod-spoke-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "dev_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
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
  resource_arn       = aws_ec2_transit_gateway.tgw.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

# Share principals (prod/dev accounts)
resource "aws_ram_principal_association" "tgw" {
  for_each           = toset(var.share_with_principals)
  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw.arn
}