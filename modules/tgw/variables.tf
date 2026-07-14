variable "name" {
  type = string
}

variable "amazon_side_asn" {
  type    = number
  default = 64512
}

variable "share_with_principals" {
  description = "Account IDs or Org/OU ARNs to share the TGW with via RAM"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}