variable "name" {
  type = string
}

variable "tgw_id" {
  type = string
}

variable "tgw_route_table_id" {
  description = "The TGW route table this attachment associates to (e.g. tgw.tgw_route_table_ids.prod_spoke)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "One subnet per AZ, dedicated to the TGW attachment"
  type        = list(string)
}

variable "enable_propagation" {
  description = "Whether this attachment's CIDR auto-propagates into its associated route table. True for spoke VPCs, typically false for the firewall/egress attachments where you're defining routes explicitly."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}