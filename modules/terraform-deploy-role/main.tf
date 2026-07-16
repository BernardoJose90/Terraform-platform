# Get current account ID for dynamic permissions
data "aws_caller_identity" "current" {}

# ✅ COMPLETE: Permissions with ALL required IAM actions
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # ✅ COMPLETE IAM permissions
  statement {
    sid    = "ManageInstanceRoles"
    effect = "Allow"
    actions = [
      # Role management
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",

      # Instance profile management
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",

      # OIDC and Policy management
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetPolicy",
      "iam:ListPolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion"
    ]
    resources = ["*"]
  }

  # CloudWatch logging
  statement {
    sid    = "VpnLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup"
    ]
    resources = ["*"]
  }

  # ✅ FIXED: SSM Parameter Store - Access to both management AND current account
  statement {
    sid    = "SSMParameterStore"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",  # Added for recursive parameter access
      "ssm:DescribeParameters",
      "ssm:PutParameter",
      "ssm:DeleteParameter"
    ]
    resources = [
      # Management account SSM parameters
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/transit-gateway/*",
      # Current account SSM parameters (where this role is deployed)
      "arn:aws:ssm:eu-west-2:${data.aws_caller_identity.current.account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${data.aws_caller_identity.current.account_id}:parameter/transit-gateway/*"
    ]
  }

  statement {
    sid       = "AssumeManagementSSMReadOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"]
  }

  # S3 state files
  statement {
    sid    = "StateFileAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*"
    ]
  }

  # ✅ FIXED: RAM Permissions - Added missing ListResourceSharePermissions
  statement {
    sid    = "RAMPermissions"
    effect = "Allow"
    actions = [
      "ram:CreateResourceShare",
      "ram:DeleteResourceShare",
      "ram:AssociateResourceShare",
      "ram:DisassociateResourceShare",
      "ram:GetResourceShares",
      "ram:GetResourceShareAssociations",
      "ram:ListResourceSharePermissions",  # 🔥 MISSING - Added this
      "ram:EnableSharingWithAwsOrganization"
    ]
    resources = ["*"]
  }

  # ✅ NEW: Network Firewall permissions (completely missing)
  statement {
    sid    = "NetworkFirewall"
    effect = "Allow"
    actions = [
      # Read operations
      "network-firewall:DescribeFirewall",
      "network-firewall:DescribeFirewallPolicy",
      "network-firewall:DescribeRuleGroup",
      "network-firewall:ListFirewalls",
      "network-firewall:ListFirewallPolicies",
      "network-firewall:ListRuleGroups",
      "network-firewall:ListTagsForResource",
      # Write operations (if you need to create/update)
      "network-firewall:CreateFirewall",
      "network-firewall:UpdateFirewall",
      "network-firewall:DeleteFirewall",
      "network-firewall:CreateFirewallPolicy",
      "network-firewall:UpdateFirewallPolicy",
      "network-firewall:DeleteFirewallPolicy",
      "network-firewall:CreateRuleGroup",
      "network-firewall:UpdateRuleGroup",
      "network-firewall:DeleteRuleGroup",
      "network-firewall:AssociateFirewallPolicy",
      "network-firewall:DisassociateFirewallPolicy"
    ]
    resources = ["*"]
  }
}
