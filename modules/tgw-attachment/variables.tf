variable "name" {
  description = "Exact value to use for the attachment's Name tag (e.g. \"tgw-attach-Egress-vpc\"). Used as-is — no suffix is appended."
  type        = string
}

variable "tgw_id" {
  type = string
}


variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "One subnet per Availability Zone (AZ), dedicated to the Transit Gateway (TGW) attachment."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
