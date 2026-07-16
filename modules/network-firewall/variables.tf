variable "name" {
  type = string
}

variable "tgw_id" {
  description = "Transit Gateway ID for firewall attachment"
  type        = string
}

variable "availability_zones" {
  description = "AZ names for firewall endpoints (e.g., eu-west-2a, eu-west-2b). These will be converted to AZ IDs automatically."
  type        = list(string)
}

variable "tgw_firewall_forwarding_route_table_id" {
  description = "The TGW route table ID for firewall forwarding (post-inspection)"
  type        = string
}

variable "prod_cidr" {
  description = "Production VPC CIDR"
  type        = string
  default     = "10.20.0.0/16"
}

variable "dev_cidr" {
  description = "Development VPC CIDR"
  type        = string
  default     = "10.30.0.0/16"
}

variable "rule_group_capacity" {
  description = "Capacity for the Suricata rule group"
  type        = number
  default     = 100
}

variable "tags" {
  type    = map(string)
  default = {}
}