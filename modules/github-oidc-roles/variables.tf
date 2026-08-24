variable "management_account_id" {
  description = "Account ID allowed to assume this role."
  type        = string
  default     = "145678291484"
}

variable "role_name" {
  description = "Name to give the Terraform deploy IAM role."
  type        = string
  default     = "TerraformDeploy"
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state, which this role needs read/write access to."
  type        = string
  default     = "james-terraform-state-2026"
}

variable "state_key_prefix" {
  description = "Folder in the state bucket this account owns. Must match the backend key."
  type        = string
}

variable "github_org" {
  description = "GitHub org or username that owns the repo, e.g. \"your-org\""
  type        = string
  default     = "BernardoJose90"
}

variable "github_repo" {
  description = "Repository name only, no org prefix, e.g. \"Terraform-platform\""
  type        = string
  default     = "Terraform-platform"
}

variable "account_name" {
  description = "Short name for this account, e.g. \"security\", \"production\" — used only for tagging."
  type        = string
}

variable "extra_assumable_role_arns" {
  description = "Additional IAM role ARNs (typically in other accounts) that this account's TerraformDeploy and TerraformPlan roles may assume — e.g. a spoke account's TGW wiring role in the network account. Empty by default; most accounts don't need this."
  type        = list(string)
  default     = []
}

# permissions_boundary_arn, extra_trusted_environments, and
# create_oidc_provider were removed 2026-08-24 — all three existed only for
# terraform-org's platform/ account, the one caller with different-enough
# needs to use any of them. That account stopped sourcing this module
# entirely (replaced with a dedicated role definition owned directly in
# that repo), and no other caller ever set any of the three. See main.tf's
# comments at each removed usage for the detail on each.
