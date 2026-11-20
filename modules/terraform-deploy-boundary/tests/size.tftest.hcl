# IAM caps a managed policy at 6,144 characters (whitespace excluded), and
# this boundary is close to it: development, the account with the most
# toggles on, was 5,922 after enable_rds was added. Going over fails only
# at apply time, and this boundary is applied through break-glass, so
# catch it here instead.
#
# Uses the real aws provider with fake credentials: aws_iam_policy_document
# is computed locally and never calls AWS. Only the caller-identity lookup
# is overridden. Account IDs are 12 digits like the real ones, so the
# measured length matches.

provider "aws" {
  region                      = "eu-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values = {
    account_id = "111111111111"
    arn        = "arn:aws:iam::111111111111:root"
    id         = "111111111111"
    user_id    = "AIDAEXAMPLE"
  }
}

# Same toggles as member-accounts/development/main.tf. If another account
# turns on more than this, add a run block for it.
run "development_boundary_fits_iam_limit" {
  command = plan

  variables {
    account_name              = "development"
    management_account_id     = "145678291484"
    state_bucket_name         = "james-terraform-state-2026"
    state_key_prefix          = "development"
    role_name                 = "TerraformDeploy"
    enable_vpc_networking     = true
    enable_eks                = true
    enable_s3                 = true
    enable_rds                = true
    extra_assumable_role_arns = ["arn:aws:iam::111111111111:role/TgwSpokeWiringDevelopment"]
  }

  assert {
    condition     = length(replace(data.aws_iam_policy_document.terraform_deploy_boundary.minified_json, "/\\s/", "")) <= 6144
    error_message = "TerraformDeployPermissionsBoundary is over IAM's 6,144-character limit for development."
  }
}
