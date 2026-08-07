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
}

# Scoped to this spoke's own route table + "main" only — the production
# role can never touch tgw-dev-spoke-rt and vice versa. This resource-level
# restriction is the entire security story of letting spokes wire
# themselves into the hub: a spoke can only ever affect its own route
# table, plus its own return-path entry in "main" — never another
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
      "ec2:GetTransitGatewayRouteTableAssociations",
      "ec2:GetTransitGatewayRouteTablePropagations",
      "ec2:SearchTransitGatewayRoutes",
    ]
    resources = var.route_table_arns
  }

  statement {
    sid    = "DescribeTgwState"
    effect = "Allow"
    actions = [
      # These describe/list actions don't support resource-level
      # restriction, unlike the route-table-scoped actions above.
      "ec2:DescribeTransitGateways",
      "ec2:DescribeTransitGatewayRouteTables",
      "ec2:DescribeTransitGatewayAttachments",
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
