output "tgw_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "tgw_arn" {
  value = aws_ec2_transit_gateway.this.arn
}

output "tgw_route_table_ids" {
  value = {
    main                = aws_ec2_transit_gateway_route_table.main.id
    firewall_forwarding = aws_ec2_transit_gateway_route_table.firewall_forwarding.id
    prod_spoke          = aws_ec2_transit_gateway_route_table.prod_spoke.id
    dev_spoke           = aws_ec2_transit_gateway_route_table.dev_spoke.id
  }
}

output "ram_resource_share_arn" {
  value = aws_ram_resource_share.tgw.arn
}