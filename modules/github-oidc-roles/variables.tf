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
