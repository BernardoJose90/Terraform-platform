variable "aws_region" {
  description = "AWS region to deploy the network environment into."
  type        = string
  default     = "eu-west-2"
}

variable "management_account_id" {
  description = "The AWS account ID of the management account."
  type        = string
  default     = "145678291484"
}

variable "amazon_side_asn" {
  description = "Amazon side ASN for the Transit Gateway"
  type        = number
  default     = 64512
}

variable "cidr" {
  description = "CIDR block for the egress VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "AZs to deploy the egress VPC, TGW attachments and Network Firewall into"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "private_subnets" {
  description = "TGW-attachment subnets, one per AZ (sub-tgw-egress-a/b)"
  type        = list(string)
  default     = ["10.10.30.0/24", "10.10.40.0/24"]
}

variable "public_subnets" {
  description = "NAT gateway subnets, one per AZ (sub-nat-egress-a/b)"
  type        = list(string)
  default     = ["10.10.50.0/24", "10.10.60.0/24"]
}

variable "prod_cidr" {
  description = "Production VPC CIDR — used by the firewall's cross-env DROP rule"
  type        = string
  default     = "10.20.0.0/16"
}

variable "dev_cidr" {
  description = "Development VPC CIDR — used by the firewall's cross-env DROP rule"
  type        = string
  default     = "10.30.0.0/16"
}

variable "tags" {
  description = "Tags applied to all resources in this account"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Environment = "network"
    Service     = "network"
  }
}
