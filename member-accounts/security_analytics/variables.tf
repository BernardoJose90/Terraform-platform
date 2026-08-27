variable "aws_region" {
  type    = string
  default = "eu-west-2"
}
variable "alert_email" {
  description = "Email address notified by this account's deploy-role-alerts SNS topic (modules/deploy-role-alerts). Required — supply via a gitignored *.auto.tfvars file, or TF_VAR_alert_email / a repo secret in CI."
  type        = string
}
