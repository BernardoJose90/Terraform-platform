# Trust policy: only the management account may assume this role.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }
  }
}

# Updated permissions with SSM access (no DynamoDB)
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances — all live under ec2:
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # Allow attaching an instance profile/role to the EC2 instance.
  statement {
    sid       = "PassRoleToEc2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Only needed if Terraform also creates the IAM role / instance profile
  statement {
    sid    = "ManageInstanceRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile"
    ]
    resources = ["*"]
  }

  # Optional: VPN tunnel logging to CloudWatch
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

  # ✅ NEW: SSM Parameter Store permissions
  statement {
    sid    = "SSMParameterStore"
    effect = "Allow"
    actions = [
      # Both read and write permissions (module is used in multiple places)
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DescribeParameters",
      "ssm:PutParameter",
      "ssm:DeleteParameter"
    ]
    # Using variable for management account ID
    resources = ["arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*"]
  }

  # ✅ NEW: S3 permissions for state files
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
}

resource "aws_iam_role" "terraform_deploy" {
  name                 = var.role_name        # fixed: role uses the variable
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "Terraform" }
}

resource "aws_iam_role_policy" "terraform_deploy" {
  name   = "TerraformDeployPermissions"       # revert: this can stay a static/internal name
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

output "role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}

# Optional: Output the role name for easier reference
output "role_name" {
  value = aws_iam_role.terraform_deploy.name
}