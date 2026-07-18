# ======================================================================================
# Terraform code which creates IAM infrastructure for GitHub Actions CI/CD with two separate roles
# ======================================================================================

# Get current account ID for dynamic permissions
data "aws_caller_identity" "read_current_account" {}

# ======================================================================================
# Creates OIDC PROVIDER IN AWS which is a trust relationship between AWS & GitHub 
# Allowing GitHub Actions to authenticate with AWS without using access keys
# ======================================================================================
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  
  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }
  
  lifecycle {
    prevent_destroy = true
  }
}

# ======================================================================================
# Trust policy for GitHub Actions - This Generates trust policy.
# ======================================================================================
data "aws_iam_policy_document" "trust" {
# Allows management account admins with MFA to assume this role (emergency access)
  statement {
    sid     = "ManagementAccountBreakGlass"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }

# Allows GitHub Actions to assume this role via OIDC
  statement {
    sid     = "GitHubActionsCI"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

# ======================================================================================
# Generates Permissions with ALL required IAM actions
# ======================================================================================
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

  #  SSM Parameter Store Access to BOTH management AND current account
  statement {
    sid    = "SSMParameterStore"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:DescribeParameters",
      "ssm:PutParameter",
      "ssm:DeleteParameter"
    ]
    resources = [
      # Management account paths
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*",
      "arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/transit-gateway/*",
      # Current account paths
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

  # S3 state files access
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

  # RAM Permissions
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
      "ram:ListResourceSharePermissions",
      "ram:EnableSharingWithAwsOrganization"
    ]
    resources = ["*"]
  }

  # Network Firewall permissions
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
      # Write operations
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

# ==============================================================================
# RESOURCE: TERRAFORM DEPLOY ROLE THIS IS THE ACTUAL RESOURCE THAT GETS CREATED
# ==============================================================================
resource "aws_iam_role" "terraform_deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  
  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }
  
  lifecycle {
    prevent_destroy = true
  }
  
  depends_on = [aws_iam_openid_connect_provider.github]
}

# ======================================================================================
# ATTACH THE PERMISSIONS POLICY TO THE terraform_deploy ROLE 
# ======================================================================================
resource "aws_iam_role_policy" "terraform_deploy_policy" {
  name   = "TerraformDeployPermissions"
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

# =======================================================================================
# Generating a trust policy that allows GitHub Actions to assume the Terraform Plan role
# =======================================================================================
data "aws_iam_policy_document" "github_oidc_trust_plan" {
  statement {
    sid     = "GitHubActionsPlan"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

# ======================================================================================
# Creates a read-only role for Github Action to run terraform plan workflow. 
# This role has limited permissions and can only read resources, not modify them.
# ======================================================================================
resource "aws_iam_role" "terraform_plan" {
  name                 = "TerraformPlan"
  assume_role_policy   = data.aws_iam_policy_document.github_oidc_trust_plan.json
  max_session_duration = 3600
  
  tags = {
    ManagedBy   = "github-actions"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }
  
  lifecycle {
    prevent_destroy = true
  }
}

# ======================================================================================
# creates an inline IAM policy that allows the Terraform Plan role to assume another role in the management account
# What it does: Allows the Terraform Plan role role to temporarily assume the SSMReadOnly role in the management account
# Why needed: To read SSM parameters from the management account during planning
# ======================================================================================
resource "aws_iam_role_policy" "terraform_plan_assume_ssm_readonly" {
  name = "AssumeManagementSSMReadOnly"
  role = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"
    }]
  })
}

# ======================================================================================
# attaches custom policy to the terraform_plan only role
# ======================================================================================
resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ======================================================================================
# Creates custom S3 policy for state file access
# ======================================================================================
resource "aws_iam_policy" "terraform_plan_s3_role" {
  name = "TerraformPlanS3Policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        "arn:aws:s3:::${var.state_bucket_name}",
        "arn:aws:s3:::${var.state_bucket_name}/*"
      ]
      Sid = "StateFileAccess"
    }]
  })
}

# ======================================================================================
# attaches custom S3 policy to the terraform_plan_s3_role
# ======================================================================================
resource "aws_iam_role_policy_attachment" "terraform_plan_s3_policy_attachment" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = aws_iam_policy.terraform_plan_s3_role.arn
}

# =============================================
# OUTPUTS
# =============================================
output "role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}

output "role_name" {
  value = aws_iam_role.terraform_deploy.name
}

output "plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}