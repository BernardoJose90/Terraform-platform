# Used to build this account's own transit-gateway-attachment ARN prefix
# for the WireOwnSpokeAttachment statement below.
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Trusts both the spoke's deploy role (apply) and plan role (read-only plan),
# so `terraform plan` can resolve the TGW wiring resources too, not just apply.
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

  # Matches the protection already on modules/github-oidc-roles' roles:
  # this is the cross-account trust anchor production/development's own
  # CI roles assume to wire TGW routing. Losing it isn't just "recreate a
  # role"; it breaks spoke plans/applies until re-applied by hand from an
  # admin session, since the very automation that would normally recreate
  # it depends on it existing.
  lifecycle {
    prevent_destroy = true
  }
}

# Scoped to this spoke's own route table plus "main" only: the production
# role can never touch tgw-dev-spoke-rt and vice versa. This resource-level
# restriction is the entire security story of letting spokes wire
# themselves into the hub: a spoke can only ever affect its own route
# table, plus its own return-path entry in "main", never another
# environment's table.
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

  # Associate/Disassociate/Enable/DisablePropagation (and Create/Replace
  # Route, which target an attachment as the route's destination) are
  # checked by AWS against BOTH the route table ARN above and the
  # transit-gateway-attachment ARN passed in the call; granting only the
  # route table above denies with UnauthorizedOperation on the attachment.
  #
  # Can't scope this to "own attachment only" the way route_table_arns
  # scopes the table: a cross-account TGW VPC attachment has a separate
  # ARN/tag namespace per account. Tags the spoke account sets (e.g.
  # Environment=production) land on the spoke's own copy of the
  # attachment; this statement is evaluated in the network (TGW-owner)
  # account against its copy, which carries none of the spoke's tags, so
  # a tag condition here can never match. This is a same-account wildcard
  # with no further restriction; the actual "can't touch another spoke's
  # table" boundary is enforced above, by the explicit route_table_arns
  # allow-list. This statement alone grants nothing without a permitted
  # route table to pair it with.
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
      # These describe/list actions don't support resource-level
      # restriction, unlike the route-table-scoped actions above.
      # GetTransitGatewayRouteTable{Associations,Propagations} are here
      # for the same reason: the waiter aws_ec2_transit_gateway_route_
      # table_association/propagation polls after Associate/Enable calls
      # to confirm "associated"/"enabled" state, and AWS only ever
      # evaluates them against the account-wide "*" resource, never the
      # specific route table ARN (confirmed by AccessDenied when scoped
      # to var.route_table_arns despite the mutating calls succeeding).
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
