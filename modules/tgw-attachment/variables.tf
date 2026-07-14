variable "name" {
  type = string
}

variable "tgw_id" {
  type = string
}

variable "tgw_route_table_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "One subnet per AZ, dedicated to the TGW attachment"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}