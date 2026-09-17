# The depends_on line here — not just the value itself — is what makes
# this actually work. It means everything that reads tgw_id (the egress
# VPC's own attachment, the SSM parameter that spoke accounts read, and
# so on) automatically waits for null_resource.wait_for_tgw_available to
# finish first, without any of those callers needing to know that wait
# exists at all.
output "tgw_id" {
  value      = aws_ec2_transit_gateway.tgw.id
  depends_on = [null_resource.wait_for_tgw_available]
}

output "tgw_arn" {
  value = aws_ec2_transit_gateway.tgw.arn
}

# Same reasoning as tgw_id above: these route table IDs feed the
# associations and propagations that Transit Gateway attachments need, so
# they also wait for the Transit Gateway to be available first.
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
