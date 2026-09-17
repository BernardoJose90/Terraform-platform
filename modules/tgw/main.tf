# Transit Gateway
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = var.name
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = merge(var.tags, { Name = var.name })
}

# This resource used to be named "this" and was later renamed to "tgw".
# Without this moved block, Terraform would interpret that rename as
# "delete the old resource, then create a new one" instead of an in-place
# rename. That would actually destroy the real Transit Gateway in AWS —
# along with everything attached to it in every account — and then
# rebuild it from scratch.
moved {
  from = aws_ec2_transit_gateway.this
  to   = aws_ec2_transit_gateway.tgw
}

# ============================================================
# Terraform considers the Transit Gateway "created" the moment AWS
# accepts the API call to create it. But behind the scenes, AWS takes
# real time afterward to actually bring it from a "pending" state to an
# "available" state — especially right after a fresh build, like a
# teardown followed by a re-enable. If anything tries to attach a VPC to
# the Transit Gateway before it's truly available, that attachment fails
# with an "IncorrectState: ... is in invalid state" error. This has
# happened for real: production and development hit it right after the
# network account's apply had already reported success (see the run for
# commit 386ff6c).
#
# There's no built-in AWS command and no fix on the Terraform side for
# this gap. The AWS provider's maintainers were asked to track attachment
# state for exactly this reason and declined the request (see
# hashicorp/terraform-provider-aws issue #18412). So instead, this
# resource polls AWS directly to check the Transit Gateway's real state,
# and only lets anything downstream continue once AWS reports
# "available". This is deliberately not a fixed-length sleep/pause: a
# fixed wait either wastes time when there's no delay to wait out, or
# isn't long enough when there is one. (We already learned this same
# lesson once before, for a similar timing issue with IAM — see the
# "ci: replace fixed time_sleep with retry-on-AccessDenied" commit.)
# ============================================================
resource "null_resource" "wait_for_tgw_available" {
  # This is keyed on the Transit Gateway's own ID. That way, if the
  # Transit Gateway is genuinely replaced (a brand new one is created),
  # this wait runs again. But an unrelated re-apply of this module won't
  # re-run the poll for a Transit Gateway that's already available.
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
# This is the mirror-image problem, but on teardown instead of creation.
# Production and development's Transit Gateway attachments are destroyed
# first (see the CI teardown order — the spoke accounts always finish
# before the network account starts). But just as apply doesn't wait for
# "available", destroy doesn't wait for "actually gone" either: AWS keeps
# reporting an attachment as "deleting" for a while after Terraform has
# already marked that spoke's destroy as complete. If the network account
# then tries to delete its route tables or the Transit Gateway itself
# while one of those attachments is still mid-delete, AWS rejects the
# request with an error like "IncorrectState: tgw-xxx has non-deleted
# Transit Gateway Attachments". This is a real, previously reported
# problem (hashicorp/terraform-provider-aws issue #7196), not a
# hypothetical edge case.
#
# Provisioners that run at destroy time can only safely reference
# `self` (this same resource). Referencing anything else may already be
# gone from Terraform's perspective by the time this runs, or it can
# create a circular dependency in the destroy order (see HashiCorp's own
# provisioner documentation on this). That's why the Transit Gateway's ID
# is captured into `triggers` when this resource is first created, and
# read back here via self.triggers, instead of referencing
# aws_ec2_transit_gateway.tgw.id directly.
# ============================================================
resource "null_resource" "wait_for_attachments_cleared" {
  triggers = {
    tgw_id = aws_ec2_transit_gateway.tgw.id
  }

  # This depends on the Transit Gateway and every route table it owns.
  # Terraform always destroys a resource's dependents before the resource
  # itself, so on teardown this resource gets destroyed first. That's the
  # whole point: it means this resource's destroy-time provisioner runs
  # and blocks first, before Terraform is allowed to touch the Transit
  # Gateway or any of its route tables.
  depends_on = [
    aws_ec2_transit_gateway.tgw,
    aws_ec2_transit_gateway_route_table.main,
    aws_ec2_transit_gateway_route_table.prod_spoke,
    aws_ec2_transit_gateway_route_table.dev_spoke,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TGW_ID="${self.triggers.tgw_id}"
      echo "Waiting for every VPC attachment on $TGW_ID to finish deleting..."

      for i in $(seq 1 60); do
        REMAINING=$(aws ec2 describe-transit-gateway-vpc-attachments \
          --filters "Name=transit-gateway-id,Values=$TGW_ID" \
          --query "length(TransitGatewayVpcAttachments[?State!=\`deleted\`])" \
          --output text 2>/dev/null || echo "0")
        echo "  [$i/60] non-deleted attachments remaining: $REMAINING"

        if [ "$REMAINING" = "0" ]; then
          echo "All attachments cleared."
          exit 0
        fi

        sleep 10
      done

      echo "Timed out after 10 minutes waiting for attachments on $TGW_ID to clear."
      exit 1
    EOT
  }
}

# ============================================================
# ROUTE TABLES. Each spoke environment gets its own Transit Gateway route
# table that only its own automation is allowed to touch: production can
# only touch prod_spoke, and development can only touch dev_spoke (this
# is enforced in modules/tgw-spoke-wiring-role). Routes never propagate
# between these two tables, so there is no direct network path between
# the production and development environments.
#
# "main" is the one route table both spokes are allowed to write to, and
# only to publish their own "return" route back to themselves. It's
# attached to the egress VPC's Transit Gateway connection, so it's the
# table that NAT return traffic actually looks up. This gives one narrow,
# deliberately shared spot, while keeping everything else fully isolated.
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
# RAM (Resource Access Manager) SHARING — this is what lets the
# production and development accounts attach to a Transit Gateway that
# actually lives in the network account.
# ============================================================
resource "aws_ram_resource_share" "tgw" {
  name                      = "${var.name}-share"
  allow_external_principals = false
  tags                      = var.tags
}

# Shares the Transit Gateway resource itself with the accounts below.
resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.tgw.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

# Grants the production and development accounts permission to use the
# shared Transit Gateway.
resource "aws_ram_principal_association" "tgw" {
  for_each           = toset(var.share_with_principals)
  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw.arn
}
