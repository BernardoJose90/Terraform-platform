# If the caller needs these resources to wait on something outside this
# module (e.g. a Transit Gateway attachment that must exist before a
# route can target it), use the module block's own depends_on meta-
# argument at the call site — it applies to every resource in here.

locals {
  # Flattened to one entry per (production_workload_subnet, az) subnet, keyed e.g. "eks-a".
  # merge({}, ...) rather than merge(...) so this still resolves cleanly
  # to {} when var.production_workload_subnets is {} (merge() with zero arguments errors;
  # the leading {} guarantees at least one).
  subnet_instances = merge({}, [
    for production_workload_subnet, cfg in var.production_workload_subnets : {
      for az_key, s in cfg.subnets : "${production_workload_subnet}-${az_key}" => merge(s, {
        production_workload_subnet = production_workload_subnet
      })
    }
  ]...)
}

resource "aws_subnet" "prod_workload_sub" {
  for_each = local.subnet_instances

  vpc_id            = var.vpc_id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  tags = merge(var.tags, { Name = each.value.name })
}

resource "aws_route_table" "prod_workload_rtb" {
  for_each = var.production_workload_subnets

  vpc_id = var.vpc_id

  tags = merge(var.tags, { Name = each.value.route_table_name })
}

resource "aws_route_table_association" "prod_workload_rtb_association" {
  for_each = local.subnet_instances

  subnet_id      = aws_subnet.prod_workload_sub[each.key].id
  route_table_id = aws_route_table.prod_workload_rtb[each.value.purpose].id
}

# Only purposes with to_tgw = true get this route — see variables.tf.
resource "aws_route" "to_tgw" {
  for_each = { for production_workload_subnet, cfg in var.production_workload_subnets : production_workload_subnet => cfg if cfg.to_tgw }

  route_table_id         = aws_route_table.prod_workload_rtb[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id
}
