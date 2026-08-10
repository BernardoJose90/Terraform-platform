variable "name" {
  description = "Full, exact value for the attachment's Name tag (e.g. \"tgw-attach-Egress-vpc\") — used as-is, no suffix appended."
  type        = string
}

variable "tgw_id" {
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