output "firewall_arn" {
  value = aws_networkfirewall_firewall.this.arn
}

output "tgw_attachment_id" {
  value = aws_networkfirewall_firewall.this.firewall_status[0].transit_gateway_attachment_sync_states[0].attachment_id
}