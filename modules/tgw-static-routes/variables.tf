variable "tgw_route_table_id" {
  type = string
}

variable "routes" {
  description = "Map of destination CIDR block (Classless Inter-Domain Routing — an IP address range) to Transit Gateway attachment ID."
  type        = map(string)
  default     = {}
}

variable "blackhole_cidrs" {
  description = "Destination CIDR blocks to explicitly drop rather than route anywhere. If a broader route in the same table also matches (e.g. 0.0.0.0/0), this one wins, because routing always picks the most specific (longest-prefix) match."
  type        = list(string)
  default     = []
}
