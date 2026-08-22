# Transit Gateway
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = var.name
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = merge(var.tags, { Name = var.name })
}

# This resource used to be named "this" and got renamed to "tgw". Without
# this moved block, Terraform would read that rename as "delete the old
# one, create a new one" instead of an in-place rename — which would tear
# down the actual Transit Gateway, and everything attached to it in every
# account, then rebuild it from scratch.
moved {
  from = aws_ec2_transit_gateway.this
  to   = aws_ec2_transit_gateway.tgw
}

# ============================================================
# Terraform considers the TGW "created" the moment AWS accepts the create
# call, but AWS's own control plane takes real time after that to bring
# it from "pending" to "available" — especially on a fresh build like a
# teardown -> re-enable cycle. Anything that tries to attach a VPC to the
# TGW before it's actually available fails with "IncorrectState: ... is
# in invalid state" — hit for real in production/development right after
# network published a "successful" apply (see commit 386ff6c's run).
#
# There's no AWS CLI waiter and no Terraform-level fix for this: the
# provider team was asked to track attachment state for exactly this
# reason and declined (hashicorp/terraform-provider-aws#18412). So this
# polls AWS directly for the real state and only lets anything downstream
# proceed once it says "available" — not a blind fixed-length sleep,
# which either wastes time when there's no race or isn't long enough
# when there is (the same lesson already learned once for the IAM race,
# see the "ci: replace fixed time_sleep with retry-on-AccessDenied"
# commit).
# ============================================================
resource "null_resource" "wait_for_tgw_available" {
  # Keyed on the TGW's own ID, so a genuine replacement (a new TGW) waits
  # again, but an unrelated re-apply of this module doesn't re-run the
  # poll for a TGW that's already available.
  triggers = {
    tgw_id = aws_ec2_transit_gateway.tgw.id
  }

  depends_on = [aws_ec2_transit_gateway.tgw]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TGW_ID="${aws_ec2_transit_gateway.tgw.id}"
      echo "Waiting for $TGW_ID to reach 'available'..."

      for i in $(seq 1 60); do
        STATE=$(aws ec2 describe-transit-gateways \
          --transit-gateway-ids "$TGW_ID" \
          --query 'TransitGateways[0].State' \
          --output text)
        echo "  [$i/60] state=$STATE"

        if [ "$STATE" = "available" ]; then
          echo "TGW is available."
          exit 0
        fi

        case "$STATE" in
          deleted|deleting|failed|failing)
            echo "TGW entered a terminal, non-available state ($STATE) — it will never become available."
            exit 1
            ;;
        esac

        sleep 10
      done

      echo "Timed out after 10 minutes waiting for $TGW_ID to become available."
      exit 1
    EOT
  }
}

# ============================================================
# ROUTE TABLES. Each spoke gets its own table that only its own automation
# can touch — production only touches prod_spoke, development only
# touches dev_spoke (enforced in modules/tgw-spoke-wiring-role) — and
# routes never propagate between them, so there's no direct path between
# the two environments. "main" is the one table both spokes are allowed to
# write to, and only to publish their own return route; it's attached to
# the egress VPC's connection, so that's what NAT return traffic actually
# consults. One narrow shared spot, everything else fully isolated.
# ============================================================
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = merge(var.tags, { Name = "tgw-Egress-vpc-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "prod_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = merge(var.tags, { Name = "tgw-prod-spoke-rt" })
}

resource "aws_ec2_transit_gateway_route_table" "dev_spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = merge(var.tags, { Name = "tgw-dev-spoke-rt" })
}

# ============================================================
# RAM SHARING
# ============================================================
resource "aws_ram_resource_share" "tgw" {
  name                      = "${var.name}-share"
  allow_external_principals = false
  tags                      = var.tags
}

# Share the TGW itself
resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.tgw.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

# Share principals (prod/dev accounts)
resource "aws_ram_principal_association" "tgw" {
  for_each           = toset(var.share_with_principals)
  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw.arn
}