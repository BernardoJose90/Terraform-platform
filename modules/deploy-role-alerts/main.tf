###############################################################################
# TerraformDeploy assume-role alerting — one instance per account
#
# Added 2026-08-26 to close the "no runtime story" gap flagged in the
# 2026-08 security review: before this, nothing watched for TerraformDeploy
# being assumed outside its intended path (GitHub Actions OIDC).
#
# Matches against this account's default 90-day CloudTrail event history,
# which EventBridge receives automatically for management events — no
# trail needs to exist in this account for this to fire. The management
# account has its own copy of this same pattern (see
# Terraform-Org/platform/security-alerts.tf), plus a parallel rule for
# BreakGlassAdmin, which only exists in that account.
###############################################################################

resource "aws_sns_topic" "deploy_role_alerts" {
  name = "${var.account_name}-deploy-role-alerts"
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
# (GitHub Actions OIDC). The only other legitimate path is BreakGlassAdmin
# assuming it cross-account from the management account with MFA — which
# is exactly the case this should still alert on, since that path is meant
# to be rare and always noticed, not silently trusted just because it's
# documented.
resource "aws_cloudwatch_event_rule" "unexpected_deploy_assume" {
  name        = "unexpected-${var.role_name}-assume"
  description = "${var.role_name} assumed by something other than GitHub Actions OIDC"

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
