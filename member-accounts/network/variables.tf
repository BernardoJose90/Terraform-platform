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
  description = "The Autonomous System Number (ASN) AWS uses to identify its side of the Transit Gateway (TGW) — a network device that connects multiple Virtual Private Clouds (VPCs) together. This is a standard, low-level networking ID that doesn't need to be changed."
  type        = number
  default     = 64512
}

variable "cidr" {
  description = "The IP address range (in CIDR notation, e.g. 10.10.0.0/16) for the egress Virtual Private Cloud (VPC)"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Availability Zones (AZs — separate, isolated data center locations within the AWS region) to deploy the egress VPC and its Transit Gateway (TGW) attachments into"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "private_subnets" {
  description = "The subnets used for the Transit Gateway (TGW) attachment, one per Availability Zone (private-sub-tgw-a/b). These are deliberately small (/28, meaning only 16 addresses) because each one only ever needs to hold the single network interface that the TGW attachment creates — a much larger /24 range was never needed here."
  type        = list(string)
  default     = ["10.10.30.0/28", "10.10.40.0/28"]
}

variable "public_subnets" {
  description = "The subnets that hold the NAT gateways, one per Availability Zone (sub-nat-egress-a/b)"
  type        = list(string)
  default     = ["10.10.50.0/24", "10.10.60.0/24"]
}

variable "prod_cidr" {
  description = "The production VPC's IP address range (CIDR block) — used to build the return-path routes in the egress VPC's public route tables, so replies to NAT'd traffic from production can find their way back"
  type        = string
  default     = "10.20.0.0/16"
}

variable "dev_cidr" {
  description = "The development VPC's IP address range (CIDR block) — used to build the return-path routes in the egress VPC's public route tables, so replies to NAT'd traffic from development can find their way back"
  type        = string
  default     = "10.30.0.0/16"
}

variable "tags" {
  description = "Tags applied to all resources in this accounts"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Environment = "network"
    Service     = "network"
  }
}

variable "networking_enabled" {
  description = <<-EOT
    Master on/off switch for the networking resources in this account
    that actually cost money (the VPC, NAT gateways, and Transit
    Gateway). Setting this to false stops that spend, while the account
    itself, its CI/CD roles, its Terraform state file, and its SSM
    Parameter Store entries all stay in place. This is a pause, not a
    full teardown.

    ORDERING: both the production and development accounts must be
    applied with this set to false BEFORE this network account is
    switched off. The Transit Gateway cannot be deleted while the spoke
    accounts still have active attachments to it.
  EOT
  type        = bool
  default     = true
}
