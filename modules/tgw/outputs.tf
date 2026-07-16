output "tgw_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "tgw_arn" {
  value = aws_ec2_transit_gateway.this.arn
}

# Map instead of a single ID, so callers pick the right table per role
# instead of everything landing on one flat table.
output "tgw_route_table_ids" {
  value = {
    firewall_forwarding = aws_ec2_transit_gateway_route_table.firewall_forwarding.id
    prod_spoke          = aws_ec2_transit_gateway_route_table.prod_spoke.id
    dev_spoke           = aws_ec2_transit_gateway_route_table.dev_spoke.id
  }
}