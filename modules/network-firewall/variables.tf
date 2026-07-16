variable "name" {
  type = string
}

variable "tgw_id" {
  type = string
}

variable "tgw_firewall_forwarding_route_table_id" {
  description = "The tgw-firewall-forwarding-rt ID from modules.tgw.tgw_route_table_ids.firewall_forwarding"
  type        = string
}

variable "availability_zones" {
  description = "AZ IDs (e.g. use1-az1) the firewall deploys endpoints into — needs to match your TGW subnets' AZs for HA"
  type        = list(string)
}

variable "prod_cidr" {
  description = "Production VPC CIDR, used in the Suricata cross-env block rule"
  type        = string
  default     = "10.20.0.0/16"
}

variable "dev_cidr" {
  description = "Development VPC CIDR, used in the Suricata cross-env block rule"
  type        = string
  default     = "10.30.0.0/16"
}

variable "rule_group_capacity" {
  description = "Capacity for the Suricata rule group. AWS charges roughly 1 capacity unit per distinct match condition in the rule string, not per line — start low and raise if apply fails with a capacity error, since this isn't the same accounting as 5-tuple rules."
  type        = number
  default     = 100
}

variable "tags" {
  type    = map(string)
  default = {}
}