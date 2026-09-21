# If whoever calls this module needs these resources to wait on something
# outside it — like a Transit Gateway attachment that has to exist before
# a route can point at it — use the calling module block's own depends_on
# at the call site. That applies to everything in this module at once.

locals {
  # Flattens the input down to one entry per (workload, AZ) subnet, keyed
  # like "eks-a" (AZ = Availability Zone, one of AWS's physically separate
  # data center locations within a region). Starts from merge({}, ...)
  # rather than merge(...) so this still comes out as {} when
  # var.development_workload_subnets is empty — merge() with zero arguments
  # is an error, so the leading {} guarantees there's always at least one
  # thing to merge.
  subnet_instances = merge({}, [
    for development_workload_subnet, cfg in var.development_workload_subnets : {
      for az_key, s in cfg.subnets : "${development_workload_subnet}-${az_key}" => merge(s, {
        development_workload_subnet = development_workload_subnet
      })
    }
  ]...)
}

resource "aws_subnet" "dev_workload_sub" {
  for_each = local.subnet_instances

  vpc_id            = var.vpc_id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  tags = merge(var.tags, { Name = each.value.name })
}

resource "aws_route_table" "dev_workload_rtb" {
  for_each = var.development_workload_subnets

  vpc_id = var.vpc_id

  tags = merge(var.tags, { Name = each.value.route_table_name })
}

resource "aws_route_table_association" "dev_workload_rtb_association" {
  for_each = local.subnet_instances

  subnet_id      = aws_subnet.dev_workload_sub[each.key].id
  route_table_id = aws_route_table.dev_workload_rtb[each.value.development_workload_subnet].id
}

# Only the workloads with to_tgw = true get this route to the Transit Gateway — see variables.tf.
resource "aws_route" "to_tgw" {
  for_each = { for development_workload_subnet, cfg in var.development_workload_subnets : development_workload_subnet => cfg if cfg.to_tgw }

  route_table_id         = aws_route_table.dev_workload_rtb[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id
}
