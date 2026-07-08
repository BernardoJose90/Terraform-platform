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



         