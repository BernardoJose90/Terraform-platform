# If the caller needs these resources to wait on something outside this
# module (e.g. a Transit Gateway attachment that must exist before a
# route can target it), use the module block's own depends_on meta-
# argument at the call site — it applies to every resource in here.

locals {
  # Flattened to one entry per (purpose, az) subnet, keyed e.g. "eks-a".
  # merge({}, ...) rather than merge(...) so this still resolves cleanly
  # to {} when var.purposes is {} (merge() with zero arguments errors;
  # the leading {} guarantees at least one).
  subnet_instances = merge({}, [
    for purpose, cfg in var.purposes : {
      for az_key, s in cfg.subnets : "${purpose}-${az_key}" => merge(s, {
        purpose = purpose
      })
    }
  ]...)
}

resource "aws_subnet" "this" {
  for_each = local.subnet_instances

  vpc_id            = var.vpc_id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  tags = merge(var.tags, { Name = each.value.name })
}

resource "aws_route_table" "this" {
  for_each = var.purposes

  vpc_id = var.vpc_id

  tags = merge(var.tags, { Name = each.value.route_table_name })
}

resource "aws_route_table_association" "this" {
  for_each = local.subnet_instances

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.value.purpose].id
}

# Only purposes with to_tgw = true get this route — see variables.tf.
resource "aws_route" "to_tgw" {
  for_each = { for purpose, cfg in var.purposes : purpose => cfg if cfg.to_tgw }

  route_table_id         = aws_route_table.this[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id
}
