# These three data sources look up basic facts about the current AWS
# account: which AWS partition it's in, which region, and its account ID.
# They're used below to build this account's own Transit Gateway
# attachment ARN (Amazon Resource Name — the unique identifier AWS uses to
# reference a specific resource) prefix, in the WireOwnSpokeAttachment
# statement further down.
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# This role (an IAM — Identity and Access Management — role is an AWS
# identity that other identities can "assume" to get temporary
# permissions) can be assumed by either of the spoke account's two CI
# roles: the one that runs a real "terraform apply", and the one that runs
# a read-only "terraform plan". Trusting both means a plan run can also
# look up the Transit Gateway (TGW) wiring resources it needs, not just a
# real apply.
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

  # This gets the same protection as the roles in modules/github-oidc-roles.
  # It's the role that production's and development's own CI pipelines
  # assume, across AWS accounts, in order to wire up their Transit Gateway
  # routing. Losing it isn't a quick fix: every spoke's plan and apply would
  # break until someone manually recreates it from an admin session. That's
  # because the automation that would normally recreate this role needs
  # this very role to already exist before it can run.
  lifecycle {
    prevent_destroy = true
  }
}

# This policy is scoped to grant access only to this one spoke's own route
# table, plus the shared "main" route table. That means production's role
# can never touch dev's route table, and dev's role can never touch
# production's. Limiting exactly which resources are listed here is really
# the entire security model behind letting spokes wire themselves into the
# hub: a spoke can only ever touch its own route table, and its own
# return-path entry in "main", never another environment's table.
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

  # For each of these actions, AWS actually checks permissions against two
  # resources at once: the route table above, AND the attachment ID used
  # in the same call. So granting access to the route table alone isn't
  # enough — the call would still be denied because of the attachment side.
  #
  # We can't narrow this down to "just this spoke's own attachment" the
  # way route_table_arns above narrows down the table. That's because a
  # tag placed on the attachment in the spoke account doesn't carry over
  # to the network account's copy of that same attachment, so a
  # tag-based condition here would never match anything.
  #
  # So this statement allows any attachment in this account (a wildcard).
  # On its own that sounds broad, but it grants nothing useful by itself —
  # the real "can't touch another spoke" boundary comes entirely from the
  # route_table_arns allow-list above. This statement only matters when
  # paired with that one.
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
      # None of these five read-only actions can be limited to specific
      # resources. This was confirmed by testing: limiting them to
      # var.route_table_arns just causes an AccessDenied error, even
      # though the mutating actions above work fine when limited that way.
      # The two GetTransitGatewayRouteTable* actions are the ones
      # Terraform calls after an Associate/Enable action, to confirm the
      # change actually took effect.
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
