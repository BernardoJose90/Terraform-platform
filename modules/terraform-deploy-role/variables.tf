variable "management_account_id" {
  description = "Account ID allowed to assume this role."
  type        = string
  default = "145678291484"
}

variable "role_name" {
  description = "Name to give the Terraform deploy IAM role."
  type        = string
  default     = "TerraformDeploy"
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state, which this role needs read/write access to."
  type        = string
  default = "james-terraform-state-2026"
}

variable "github_org" {
  description = "GitHub org or username that owns the repo, e.g. \"your-org\""
  type        = string
  default = "BernardoJose90"
}

variable "github_repo" {
  description = "Repository name only, no org prefix, e.g. \"Terraform-platform\""
  type        = string
  default = "Terraform-platform"
}

variable "account_name" {
  description = "Short name for this account, e.g. \"security\", \"production\" — used only for tagging."
  type        = string
}

variable "github_environment" {
  description = <<-EOT
    Required. Name of the GitHub Environment the CI job assumes this role
    from (e.g. "management-approval"). The trust policy only accepts the
    environment-scoped OIDC subject, "repo:ORG/REPO:environment:NAME" — there
    is no ref-based fallback, so every job that assumes this role must go
    through this environment's protection rules (required reviewers). Leaving
    this empty produces a trust policy that matches no possible login and
    permanently locks the role out — this is intentional fail-closed
    behaviour, not a bug: it's safer for a misconfigured caller to be unable
    to log in at all than to silently fall back to a weaker, unreviewed path.
  EOT
  type        = string
}

variable "permissions_boundary_arn" {
  description = <<-EOT
    Optional ARN of an IAM permissions boundary to attach to the
    TerraformDeploy role. This module's own `permissions` policy above is
    shared across every account that calls this module and is written wide
    (ec2:*, unconstrained iam:CreateRole/AttachRolePolicy, VPN logging) for
    accounts that actually run that kind of infrastructure. A boundary caps
    what's *usable* for one specific caller without narrowing the shared
    policy itself, so accounts that do need the wide grant are unaffected.
    Leave unset (the default) for no boundary — the role's effective
    permissions are then exactly what `permissions` above grants, unchanged
    from before this variable existed.
  EOT
  type        = string
  default     = null
}
