variable "name" {
  type = string
}

variable "amazon_side_asn" {
  type    = number
  default = 64512
}

variable "share_with_principals" {
  description = "Account IDs or AWS Organizations/Organizational Unit (OU) ARNs to share the Transit Gateway (TGW) with, using AWS Resource Access Manager (RAM)."
  type        = list(string)
  sensitive   = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
