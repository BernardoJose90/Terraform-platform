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

resource "aws_iam_role" "terraform_deploy" {
  name                 = "TerraformDeploy"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "Terraform" }
}

# Starter permissions — broad but simple for now.
data "aws_iam_policy_document" "permissions" {
  # VPC, Site-to-Site VPN, and EC2 instances — all live under ec2:
  statement {
    sid       = "NetworkAndCompute"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # Allow attaching an instance profile/role to the EC2 instance.
  # Scoped so it can only pass roles to EC2, nothing else.
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
  # for the server (for SSM, MGN agent, etc.). Drop this block if you
  # attach an existing role instead.
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

  # Optional: VPN tunnel logging to CloudWatch (if you enable it on the connection)
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
}

resource "aws_iam_role_policy" "terraform_deploy" {
  name   = "TerraformDeployPermissions"
  role   = aws_iam_role.terraform_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

output "role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}