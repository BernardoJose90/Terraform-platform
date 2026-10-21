##############################################################################
# Account: Infra Shared Services (renamed from Security Analytics)
# Purpose: For shared services
##############################################################################

terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket = "james-terraform-state-2026" # same bucket as management
    # Deliberately left as the pre-rename key — renaming it would require a
    # live state migration (terraform init -migrate-state) against this
    # account's already-deployed IAM roles, for no functional benefit: this
    # string is an internal state-storage detail, not user-facing. See
    # terraform-org/platform/state-bucket-policy.tf's state_bucket_prefix_overrides.
    key          = "security-analytics/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true # native S3 locking
    encrypt      = true
  }
}

# Provider for reading SSM (Systems Manager) parameters from the
# management account (cross-account role).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "infra_shared_services_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/infra_shared_services"
}

# Needed to grant development's and production's EKS node roles pull
# access to the shared ECR registry below.
data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# Main provider for the infra_shared_services account itself, no profile needed.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.infra_shared_services_account_id.value]

}

# Caps the TerraformDeploy role at exactly the baseline permissions
# every account needs, plus enable_ecr for the shared ECR registry below.
module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "infra-shared-services"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "security-analytics" # must match the backend "s3" key above — not renamed, see header comment
  role_name             = "TerraformDeploy"

  enable_ecr = true

  # event-network-hub's own OIDC push role (below) — a fixed, known name
  # this account creates, same pattern as network's TGW spoke-wiring
  # roles.
  manage_named_roles = [
    "EventNetworkHubEcrPush",
  ]
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "infra-shared-services"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "security-analytics" # must match the backend "s3" key above — not renamed, see header comment
  role_name             = "TerraformDeploy"

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}

# Shared, centralized registry for event-network-hub's container images —
# build once here, pull cross-account from wherever it's actually running.
# Production's account ID is included even though it has no EKS cluster
# yet (same "harmless, just inert until the cluster exists" reasoning as
# assigning EKS-Admin to production early).
module "ecr_event_network_hub" {
  source = "../../modules/ecr"

  repository_name = "event-network-hub"

  read_access_account_ids = [
    data.aws_ssm_parameter.development_account_id.value,
    data.aws_ssm_parameter.production_account_id.value,
  ]

  push_role_arn = aws_iam_role.event_network_hub_push.arn

  tags = var.tags
}

# ======================================================================================
# Push role for event-network-hub's own CI/CD — a separate, app-specific
# concern from this account's Terraform deploy pipeline (TerraformDeploy/
# TerraformPlan above), so it's plain resources here rather than added to
# modules/github-oidc-roles, which exists only for that pipeline.
#
# Trusts the SAME OIDC provider module.github-oidc-roles already created
# in this account (only one provider per unique URL is allowed per
# account — this can't create a second one for the same URL). The ARN is
# built the same deterministic way that module builds it internally,
# since it isn't exposed as an output.
# ======================================================================================
data "aws_iam_policy_document" "event_network_hub_push_trust" {
  statement {
    sid     = "EventNetworkHubCI"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_ssm_parameter.infra_shared_services_account_id.value}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Scoped to the main branch specifically, not the whole repo
    # (repo:org/repo:*) — only a workflow run that's actually on main can
    # push an image. Tighten this further to a specific GitHub
    # Environment sub (repo:org/repo:environment:name), matching
    # modules/github-oidc-roles' own convention, once one exists for
    # this repo.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:BernardoJose90/event-network-hub:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "event_network_hub_push" {
  name                 = "EventNetworkHubEcrPush"
  assume_role_policy   = data.aws_iam_policy_document.event_network_hub_push_trust.json
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "event_network_hub_push_permissions" {
  statement {
    sid    = "EcrAuth"
    effect = "Allow"
    # GetAuthorizationToken doesn't support resource-level scoping —
    # every ECR push/pull call needs it, regardless of which repository.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [module.ecr_event_network_hub.repository_arn]
  }
}

resource "aws_iam_role_policy" "event_network_hub_push" {
  name   = "EventNetworkHubEcrPush"
  role   = aws_iam_role.event_network_hub_push.id
  policy = data.aws_iam_policy_document.event_network_hub_push_permissions.json
}
