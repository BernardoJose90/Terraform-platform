variable "management_account_id" {
  description = "Account ID that owns SSMReadOnly and the /organizations/* SSM tree this boundary allows reading."
  type        = string
}

variable "account_name" {
  description = "Short name for this account, e.g. \"production\" — used only for tagging."
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state. Must match what's passed to modules/github-oidc-roles for this account."
  type        = string
}

variable "state_key_prefix" {
  description = "Folder in the state bucket this account owns. Must match what's passed to modules/github-oidc-roles for this account."
  type        = string
}

variable "role_name" {
  description = "Name of the TerraformDeploy role this boundary attaches to. Must match modules/github-oidc-roles' role_name for this account."
  type        = string
  default     = "TerraformDeploy"
}

variable "plan_role_name" {
  description = "Name of the read-only TerraformPlan role modules/github-oidc-roles always creates as \"TerraformPlan\" (not itself configurable there)."
  type        = string
  default     = "TerraformPlan"
}

variable "extra_assumable_role_arns" {
  description = "Role ARNs this account's github-oidc-roles call also passes as extra_assumable_role_arns (e.g. a spoke's TGW wiring role in the network account). Must match that call exactly, or TerraformDeploy/TerraformPlan will hold a grant this boundary doesn't actually let them use."
  type        = list(string)
  default     = []
}

variable "enable_vpc_networking" {
  description = <<-EOT
    Turns on EC2/VPC access, plus the IAM role/KMS key/CloudWatch log
    group that modules/vpc's flow logging creates (on by default there).
    Set true for an account that calls modules/vpc and/or
    modules/tgw-attachment — currently production, development, network.
  EOT
  type        = bool
  default     = false
}

variable "enable_ram_sharing" {
  description = "Turns on AWS RAM (Resource Access Manager) permissions — set true only for an account that shares a resource via RAM, currently just network (modules/tgw's TGW share to the spokes)."
  type        = bool
  default     = false
}

variable "enable_sso_management" {
  description = "Turns on IAM Identity Center (SSO) + Identity Store admin permissions — set true only for the account delegated as SSO admin, currently just security (sso.tf, iam-supplemental.tf)."
  type        = bool
  default     = false
}

variable "manage_named_roles" {
  description = <<-EOT
    Names (not ARNs — this account's own account ID is added
    automatically) of additional IAM roles, beyond TerraformDeploy/
    TerraformPlan, that this account's Terraform manages under a fixed,
    known name. E.g. network passes its two spoke-wiring role names here
    (modules/tgw-spoke-wiring-role). Not for a role with a
    Terraform-generated name (like a VPC's flow-log delivery role, which
    enable_vpc_networking already covers with a wider grant, since no
    fixed ARN can be known ahead of time for that one).
  EOT
  type        = list(string)
  default     = []
}

variable "extra_policy_json" {
  description = <<-EOT
    Escape hatch for a genuinely one-off need that doesn't fit any of the
    enable_*/manage_named_roles toggles above (typically a
    `data.aws_iam_policy_document`'s `.json` output, built by the calling
    account) merged into this boundary via source_policy_documents. Adding
    a proper toggle above is almost always the better choice, even for
    something only one account needs today — it keeps the actual IAM
    statement text in this module's main.tf, in one place, instead of
    duplicated (and free to drift) across account files. Reach for this
    only when a toggle would be pure one-off noise with no realistic
    second caller.
    Leave unset (empty string, the default) for an account with no needs
    beyond the baseline and the toggles above.
  EOT
  type        = string
  default     = ""
}
