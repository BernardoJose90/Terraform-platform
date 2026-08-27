###############################################################################
# TerraformDeploy assume-role alerting — one instance per account
#
# Added 2026-08-26 to close the "no runtime story" gap flagged in the
# 2026-08 security review: before this, nothing watched for TerraformDeploy
# being assumed outside its intended path (GitHub Actions OIDC).
#
# What this buys us, given the trust policy (see modules/github-oidc-roles)
# already only allows GitHub OIDC — specific repo + 3 named environments —
# and management-account BreakGlass-with-MFA:
#
#   * A direct unauthorized assume is impossible: it fails with AccessDenied,
#     so there is no successful event to catch. The trust policy is the
#     control there, not this rule.
#   * This rule's real job is to notify on the one assume path that is
#     allowed but meant to be rare and always noticed — management-account
#     BreakGlass. Every plain AssumeRole on this role (as opposed to
#     AssumeRoleWithWebIdentity) is that path, and a human should see each.
#
# Matches against this account's default 90-day CloudTrail event history,
# which EventBridge receives automatically for management events — no trail
# needs to exist in this account. BUT AssumeRole is a *read-only* management
# event, and a plain state = ENABLED rule ignores those: the rule below must
# set state = ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS or it silently
# matches nothing.
#
# The management account has its own copy of this same pattern (see
# Terraform-Org/platform/security-alerts.tf), plus a parallel rule for
# BreakGlassAdmin, which only exists in that account.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# SNS server-side encryption needs a customer-managed key, not the
# AWS-managed alias/aws/sns: EventBridge can only publish to an encrypted
# topic if the key policy grants events.amazonaws.com kms:Decrypt +
# kms:GenerateDataKey*, and the AWS-managed key's policy can't be edited.
data "aws_iam_policy_document" "deploy_role_alerts_kms" {
  # Without an explicit grant back to the account root, this account's own
  # IAM policies would lose all control over the key — a key's policy is
  # the only thing AWS checks for a principal it doesn't otherwise name.
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowEventBridgePublishToEncryptedTopic"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"] # "this key" — a key policy only ever scopes its own key
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "deploy_role_alerts" {
  description             = "CMK for ${var.account_name}-deploy-role-alerts SNS topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.deploy_role_alerts_kms.json
}

resource "aws_kms_alias" "deploy_role_alerts" {
  name          = "alias/${var.account_name}-deploy-role-alerts"
  target_key_id = aws_kms_key.deploy_role_alerts.key_id
}

resource "aws_sns_topic" "deploy_role_alerts" {
  name              = "${var.account_name}-deploy-role-alerts"
  kms_master_key_id = aws_kms_key.deploy_role_alerts.key_id
}


resource "aws_sns_topic_subscription" "deploy_role_alerts_email" {
  topic_arn = aws_sns_topic.deploy_role_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "deploy_role_alerts_topic_policy" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.deploy_role_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "deploy_role_alerts" {
  arn    = aws_sns_topic.deploy_role_alerts.arn
  policy = data.aws_iam_policy_document.deploy_role_alerts_topic_policy.json
}

# In normal operation every assumption of this role is
# AssumeRoleWithWebIdentity with userIdentity.type == "WebIdentityUser"
# (GitHub Actions OIDC). The only other path the trust policy permits is
# BreakGlassAdmin assuming it cross-account from the management account
# with MFA — plain AssumeRole, userIdentity.type Root/IAMUser/AssumedRole.
# That is exactly what this alerts on: rare by design, always noticed.
#
# state: AssumeRole / AssumeRoleWithWebIdentity are read-only management
# events, which a plain ENABLED rule drops. ENABLED_WITH_ALL_CLOUDTRAIL_
# MANAGEMENT_EVENTS is the documented opt-in and the only reason this rule
# fires at all.
resource "aws_cloudwatch_event_rule" "unexpected_deploy_assume" {
  name        = "unexpected-${var.role_name}-assume"
  description = "${var.role_name} assumed by something other than GitHub Actions OIDC (i.e. BreakGlass)"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AssumeRole", "AssumeRoleWithWebIdentity"]
      requestParameters = {
        roleArn = [{ suffix = ":role/${var.role_name}" }]
      }
      userIdentity = {
        type = [{ "anything-but" = ["WebIdentityUser"] }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "unexpected_deploy_assume" {
  rule = aws_cloudwatch_event_rule.unexpected_deploy_assume.name
  arn  = aws_sns_topic.deploy_role_alerts.arn
}

# ---------------------------------------------------------------------------
# TODO(security-review 2026-08): detect tampering with this role's trust
# policy / attached policies / permissions boundary — i.e. iam:
# UpdateAssumeRolePolicy, {Attach,Detach,Put,Delete}RolePolicy,
# {Put,Delete}RolePermissionsBoundary on role/${var.role_name}.
#
# NOT done here, on purpose:
#   * IAM is a global service; its CloudTrail events only reach EventBridge
#     in us-east-1, and they land on the *owning* account's default bus.
#     Catching them from this module would mean a us-east-1 provider AND a
#     second us-east-1 SNS topic in all 6 member stacks (EventBridge has no
#     cross-region SNS target) — 2-region resource sprawl per account.
#   * The clean home is the org account: point the org CloudTrail at a
#     CloudWatch Logs group and add one metric-filter + alarm per role, or
#     a CloudTrail Lake scheduled query. One place, every account, incl.
#     future ones. Tracked for Terraform-Org/platform/security-alerts.tf.
# ---------------------------------------------------------------------------
