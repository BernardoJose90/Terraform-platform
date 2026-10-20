# ======================================================================================
# Input variables for the shared ECR module. Only what genuinely differs
# per repository is exposed here — see main.tf's header comment for what's
# deliberately hardcoded instead and why.
# ======================================================================================

variable "repository_name" {
  description = "Repository name, e.g. \"event-network-hub\"."
  type        = string
}

variable "read_access_account_ids" {
  description = "AWS account IDs allowed to pull from this repository (e.g. development and production's account IDs). Granted at the account-root level, matching AWS's own documented cross-account ECR pattern — it's each account's own IAM policy (e.g. its EKS node role's AmazonEC2ContainerRegistryReadOnly) that actually decides which identity within that account can use it, not this policy."
  type        = list(string)
  default     = []
}

variable "push_role_arn" {
  description = "ARN of the one role allowed to push to this repository — typically a GitHub Actions OIDC role scoped to the one app/repo that owns these images. null means nothing can push yet."
  type        = string
  default     = null
}

variable "untagged_image_expiry_days" {
  description = "Expire untagged images after this many days. Tagged images are never auto-expired by this policy — those represent real, deployed versions you may need for rollback or audit."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to the repository."
  type        = map(string)
  default     = {}
}
