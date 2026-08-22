# depends_on here (not just the value expression) is what makes this
# actually work: everything that reads tgw_id — the egress VPC's own
# attachment, the SSM parameter spokes read, all of it — waits for
# null_resource.wait_for_tgw_available to finish first, without each of
# those callers needing to know the wait exists.
output "tgw_id" {
  value      = aws_ec2_transit_gateway.tgw.id
  depends_on = [null_resource.wait_for_tgw_available]
}

output "tgw_arn" {
  value = aws_ec2_transit_gateway.tgw.arn
}

# Same reasoning as tgw_id above — these feed the route table
# associations/propagations that attachments need, so they wait too.
output "tgw_route_table_ids" {
  value = {
    main       = aws_ec2_transit_gateway_route_table.main.id
    prod_spoke = aws_ec2_transit_gateway_route_table.prod_spoke.id
    dev_spoke  = aws_ec2_transit_gateway_route_table.dev_spoke.id
  }
  depends_on = [null_resource.wait_for_tgw_available]
}

output "ram_resource_share_arn" {
  value = aws_ram_resource_share.tgw.arn
}