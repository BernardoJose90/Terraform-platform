variable "name" {
  description = "Identity and Access Management (IAM) role name — must be unique within the network account (e.g. TgwSpokeWiringProduction)."
  type        = string
}

variable "spoke_account_id" {
  description = "The single spoke account trusted to assume this role."
  type        = string
}

variable "spoke_deploy_role_name" {
  description = "Name of the IAM role in the spoke account that runs terraform apply."
  type        = string
  default     = "TerraformDeploy"
}

variable "spoke_plan_role_name" {
  description = "Name of the IAM role in the spoke account that runs terraform plan."
  type        = string
  default     = "TerraformPlan"
}

variable "route_table_arns" {
  description = "Transit Gateway (TGW) route table Amazon Resource Names (ARNs) this role may associate, propagate, or add routes into. This should be the spoke's own route table plus the main one — never another spoke's table."
  type        = list(string)
}

variable "ssm_parameter_arns" {
  description = "Systems Manager (SSM) parameter ARNs, in this account, that this role may read — tgw_id, ram_resource_share_arn, and the route table IDs it needs."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
