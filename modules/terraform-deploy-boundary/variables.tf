variable "management_account_id" {
  description = "Account ID that owns SSMReadOnly and the /organizations/* Systems Manager (SSM) parameter tree that this boundary allows reading."
  type        = string
}

variable "account_name" {
  description = "Short name for this account, e.g. \"production\" — used only for tagging."
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket that holds Terraform state. Must match what's passed to modules/github-oidc-roles for this account."
  type        = string
}

variable "state_key_prefix" {
  description = "Folder in the state bucket that this account owns. Must match what's passed to modules/github-oidc-roles for this account."
  type        = string
}

variable "role_name" {
  description = "Name of the TerraformDeploy role that this boundary attaches to. Must match modules/github-oidc-roles' role_name for this account."
  type        = string
  default     = "TerraformDeploy"
}

variable "plan_role_name" {
  description = "Name of the read-only TerraformPlan role. modules/github-oidc-roles always creates it as \"TerraformPlan\" — that name isn't itself configurable there."
  type        = string
  default     = "TerraformPlan"
}

variable "extra_assumable_role_arns" {
  description = "Role Amazon Resource Names (ARNs) that this account's github-oidc-roles call also passes as extra_assumable_role_arns (e.g. a spoke's Transit Gateway (TGW) wiring role in the network account). Must match that call exactly, or TerraformDeploy/TerraformPlan will hold a grant that this boundary doesn't actually let them use."
  type        = list(string)
  default     = []
}

variable "enable_vpc_networking" {
  description = <<-EOT
    Turns on EC2/Virtual Private Cloud (VPC) access, plus the Identity and
    Access Management (IAM) role, Key Management Service (KMS) key, and
    CloudWatch log group that modules/vpc's flow logging creates (that
    flow logging is on by default there).

    Set this to true for an account that calls modules/vpc and/or
    modules/tgw-attachment — currently production, development, and
    network.
  EOT
  type        = bool
  default     = false
}

variable "enable_ram_sharing" {
  description = "Turns on AWS Resource Access Manager (RAM) permissions. Set this to true only for an account that shares a resource via RAM — currently just network (modules/tgw's Transit Gateway (TGW) share to the spokes)."
  type        = bool
  default     = false
}

variable "enable_sso_management" {
  description = "Turns on IAM Identity Center (Single Sign-On, or SSO) plus Identity Store admin permissions. Set this to true only for the account delegated as SSO admin — currently just security (sso.tf, iam-supplemental.tf)."
  type        = bool
  default     = false
}

variable "manage_named_roles" {
  description = <<-EOT
    Names — not Amazon Resource Names (ARNs); this account's own account
    ID is added automatically — of additional Identity and Access
    Management (IAM) roles, beyond TerraformDeploy/TerraformPlan, that
    this account's Terraform manages under a fixed, known name. For
    example, network passes its two spoke-wiring role names here
    (modules/tgw-spoke-wiring-role).

    Don't use this for a role with a Terraform-generated name, such as a
    VPC's flow-log delivery role. enable_vpc_networking already covers
    that case with a wider grant, since no fixed ARN can be known ahead
    of time for a generated name.
  EOT
  type        = list(string)
  default     = []
}

variable "extra_policy_json" {
  description = <<-EOT
    Escape hatch for a genuinely one-off need that doesn't fit any of the
    enable_*/manage_named_roles toggles above. This is typically a
    `data.aws_iam_policy_document`'s `.json` output, built by the calling
    account, and merged into this boundary via source_policy_documents.

    Adding a proper toggle above is almost always the better choice, even
    for something only one account needs today. It keeps the actual
    Identity and Access Management (IAM) statement text in this module's
    main.tf, in one place, instead of duplicated — and free to drift —
    across account files. Reach for this variable only when a toggle
    would be pure one-off noise with no realistic second caller.

    Leave this unset (empty string, the default) for an account with no
    needs beyond the baseline and the toggles above.
  EOT
  type        = string
  default     = ""
}
