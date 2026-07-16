# ============================================================
# Data source to get AZ IDs from AZ names
# ============================================================
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Convert AZ names (eu-west-2a) to AZ IDs (euw2-az1)
  az_id_map = {
    for az in data.aws_availability_zones.available.names : 
    az => data.aws_availability_zones.available.zone_ids[index(data.aws_availability_zones.available.names, az)]
  }
  
  # Convert the provided AZ names to AZ IDs
  availability_zone_ids = [
    for az in var.availability_zones : 
    local.az_id_map[az]
  ]
}

# Stateful rule group
resource "aws_networkfirewall_rule_group" "cross_env_block" {
  capacity = var.rule_group_capacity
  name     = "${var.name}-cross-env-block"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      stateful_rule {
        action = "DROP"
        header {
          protocol         = "IP"
          source           = var.dev_cidr
          source_port      = "ANY"
          destination      = var.prod_cidr
          destination_port = "ANY"
          direction        = "ANY"
        }
        rule_option {
          keyword = "sid:1"
        }
      }
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
      rule_order = "DEFAULT_ACTION_ORDER"
    }
  }

  tags = var.tags
}

# ============================================================
# ✅ TGW-attached firewall with dynamic AZ ID conversion
# ============================================================
resource "aws_networkfirewall_firewall" "this" {
  name                = var.name
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn

  transit_gateway_id = var.tgw_id

  dynamic "availability_zone_mapping" {
    for_each = local.availability_zone_ids
    content {
      availability_zone_id = availability_zone_mapping.value
    }
  }

  tags = var.tags
}

# Associate the firewall's TGW attachment with the firewall-forwarding route table
resource "aws_ec2_transit_gateway_route_table_association" "firewall" {
  transit_gateway_attachment_id  = aws_networkfirewall_firewall.this.firewall_status[0].transit_gateway_attachment_sync_states[0].attachment_id
  transit_gateway_route_table_id = var.tgw_firewall_forwarding_route_table_id
}