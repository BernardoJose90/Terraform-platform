variable "account_name" {
  description = "Short name for this account, e.g. \"production\" — used only for tagging and the SNS topic/rule names, so a run against every account doesn't collide on resource names anywhere (it wouldn't, since these are per-account resources, but it makes the CloudTrail source obvious at a glance in the console)."
  type        = string
}

variable "role_name" {
  description = "Name of the TerraformDeploy role to watch. Must match modules/github-oidc-roles' role_name for this account."
  type        = string
  default     = "TerraformDeploy"
}

variable "alert_email" {
  description = "Email address to notify on unexpected TerraformDeploy use in this account. Required — supply via a gitignored *.auto.tfvars file, or TF_VAR_alert_email / a repo secret in CI. No default: an alarm nobody receives is worse than an obviously-missing one."
  type        = string
}
