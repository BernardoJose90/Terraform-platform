output "tgw_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "tgw_arn" {
  value = aws_ec2_transit_gateway.this.arn
}

output "tgw_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.main.id
}