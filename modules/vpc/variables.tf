variable "name" {
  type = string
}

variable "cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "private_subnets" {
  type = list(string)
}

variable "public_subnets" {
  type    = list(string)
  default = []
}

variable "enable_nat_gateway" {
  description = "Set true only for the network account's NAT/egress VPC"
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "one_nat_gateway_per_az" {
  type    = bool
  default = false
}

variable "tgw_id" {
  description = "If set, adds a 0.0.0.0/0 route from private subnets to this TGW (spoke VPCs)"
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}