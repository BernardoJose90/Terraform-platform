# ======================================================================================
# Input variables for the shared S3 module. Only what genuinely differs
# per account/use is exposed here — see main.tf's header comment for
# what's deliberately hardcoded instead and why.
# ======================================================================================

variable "bucket_name" {
  description = "Full, globally-unique bucket name, e.g. \"event-network-hub-dev-exports-<account_id>\" — S3 bucket names are unique across all of AWS, not just this account, so the caller is responsible for making this unique."
  type        = string
}

variable "force_destroy" {
  description = "Allow Terraform to delete this bucket even if it still has objects in it. true is reasonable for dev (convenience); false for production (never delete real data by accident)."
  type        = bool
}

variable "expiration_days" {
  description = "Automatically expire (delete) objects after this many days. null means objects are kept indefinitely — appropriate for data you don't want auto-deleted; set this for things like generated reports/exports that don't need to be kept forever."
  type        = number
  default     = null
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
