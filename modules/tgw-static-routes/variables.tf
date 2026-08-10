variable "tgw_route_table_id" {
  type = string
}

variable "routes" {
  description = "Map of destination CIDR -> transit gateway attachment ID"
  type        = map(string)
  default     = {}
}

variable "blackhole_cidrs" {
  description = "Destination CIDRs to explicitly drop rather than route anywhere. Wins over a broader route (e.g. 0.0.0.0/0) to the same table via longest-prefix-match."
  type        = list(string)
  default     = []
}