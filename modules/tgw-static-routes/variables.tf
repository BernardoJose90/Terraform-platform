variable "tgw_route_table_id" {
  type = string
}

variable "routes" {
  description = "Map of destination CIDR -> transit gateway attachment ID"
  type        = map(string)
}