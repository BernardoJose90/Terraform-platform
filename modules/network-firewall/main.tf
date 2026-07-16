# Stateful rule group using Suricata-compatible rule strings.
# The "<>" operator matches traffic in EITHER direction, so this single
# rule blocks Prod->Dev and Dev->Prod without needing a mirrored pair.
resource "aws_networkfirewall_rule_group" "cross_env_block" {
  capacity = var.rule_group_capacity
  name     = "${var.name}-cross-env-block"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_string = <<-EOT
        drop ip ${var.prod_cidr} any <> ${var.dev_cidr} any (msg:"Block Prod-Dev cross-environment traffic"; sid:1; rev:1;)
      EOT
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = var.tags
}

resource "aws_networkfirewall_firewall_policy" "this" {
  name = "${var.name}-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.cross_env_block.arn
    }

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    # Suricata rules_string rule groups need an explicit default action —
    # without this, traffic not matching any stateful rule falls through
    # to implicit pass, which quietly defeats "blocked by default."
    stateful_default_actions = ["aws:drop_established", "aws:alert_established"]
  }

  tags = var.tags
}

# TGW-attached firewall. Requires an AWS provider version that supports
# transit_gateway_id / availability_zone_mapping on this resource —
# confirm against your pinned provider's docs before applying.
resource "aws_networkfirewall_firewall" "this" {
  name                = var.name
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn
  transit_gateway_id  = var.tgw_id

  dynamic "availability_zone_mapping" {
    for_each = var.availability_zones
    content {
      availability_zone_id = availability_zone_mapping.value
    }
  }

  tags = var.tags
}

# Associate the firewall's TGW attachment with the firewall-forwarding
# route table (the "post-inspection router" in the design doc).
resource "aws_ec2_transit_gateway_route_table_association" "firewall" {
  transit_gateway_attachment_id  = aws_networkfirewall_firewall.this.firewall_status[0].transit_gateway_attachment_sync_states[0].attachment_id
  transit_gateway_route_table_id = var.tgw_firewall_forwarding_route_table_id
}