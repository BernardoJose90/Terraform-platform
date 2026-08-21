# Feeds into building this account's own transit-gateway-attachment ARN
# prefix, used in the WireOwnSpokeAttachment statement below.
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Trusts both the spoke's deploy role and its plan role, not just the
# deploy role — so that a read-only `terraform plan` can also resolve the
# TGW wiring resources, not only a real apply.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${var.spoke_account_id}:role/${var.spoke_deploy_role_name}",
        "arn:aws:iam::${var.spoke_account_id}:role/${var.spoke_plan_role_name}",
      ]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600

  tags = var.tags

  # Same protection as the roles in modules/github-oidc-roles: this is the
  # role production and development's own CI roles assume across accounts
  # to wire up their TGW routing. Losing it isn't a quick "just recreate
  # it" — it breaks every spoke plan and apply until someone fixes it by
  # hand from an admin session, since the automation that would normally
  # recreate this role needs this same role to already exist.
  lifecycle {
    prevent_destroy = true
  }
}

# This is scoped to just this spoke's own route table, plus the shared
# "main" table — so production's role can never touch dev's route table,
# and vice versa. That resource-level limit is really the whole security
# story behind letting spokes wire themselves into the hub: a spoke can
# only ever touch its own route table and its own return-path entry in
# "main", never another environment's table.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid    = "WireOwnSpokeRouteTable"
    effect = "Allow"
    actions = [
      "ec2:AssociateTransitGatewayRouteTable",
      "ec2:DisassociateTransitGatewayRouteTable",
      "ec2:EnableTransitGatewayRouteTablePropagation",
      "ec2:DisableTransitGatewayRouteTablePropagation",
      "ec2:CreateTransitGatewayRoute",
      "ec2:DeleteTransitGatewayRoute",
      "ec2:ReplaceTransitGatewayRoute",
      "ec2:SearchTransitGatewayRoutes",
    ]
    resources = var.route_table_arns
  }

  # AWS checks each of these actions against two ARNs at once: the route
  # table above, AND the attachment ARN in the same call. Granting only the
  # table isn't enough — the call still gets denied on the attachment side.
  # This can't be scoped down to "just this spoke's own attachment" the way
  # route_table_arns scopes the table, because a spoke's own tags don't
  # carry over to the network account's copy of the attachment, so a tag
  # condition here would just never match anything. So this statement is
  # a same-account wildcard on its own — the actual "can't touch another
  # spoke" boundary is entirely the route_table_arns allow-list above; on
  # its own, this grants nothing without a permitted route table to pair it
  # with.
  statement {
    sid    = "WireOwnSpokeAttachment"
    effect = "Allow"
    actions = [
      "ec2:AssociateTransitGatewayRouteTable",
      "ec2:DisassociateTransitGatewayRouteTable",
      "ec2:EnableTransitGatewayRouteTablePropagation",
      "ec2:DisableTransitGatewayRouteTablePropagation",
      "ec2:CreateTransitGatewayRoute",
      "ec2:ReplaceTransitGatewayRoute",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:transit-gateway-attachment/*"]
  }

  statement {
    sid    = "DescribeTgwState"
    effect = "Allow"
    actions = [
      # None of these five actions support being scoped down to specific
      # resources — confirmed by testing: scoping them to
      # var.route_table_arns just returns AccessDenied, even though the
      # mutating calls above work fine when scoped that way. The two
      # GetTransitGatewayRouteTable* actions are what Terraform polls
      # after an Associate/Enable call, to confirm it actually took effect.
      "ec2:DescribeTransitGateways",
      "ec2:DescribeTransitGatewayRouteTables",
      "ec2:DescribeTransitGatewayAttachments",
      "ec2:GetTransitGatewayRouteTableAssociations",
      "ec2:GetTransitGatewayRouteTablePropagations",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadPublishedTgwParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = var.ssm_parameter_arns
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}Permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
