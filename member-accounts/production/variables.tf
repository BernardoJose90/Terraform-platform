variable "aws_region" {
  description = "AWS region to deploy the production environment into."
  type        = string
  default     = "eu-west-2"

}

variable "cidr" {
  description = "CIDR block (an IP address range) for the production Virtual Private Cloud (VPC)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability Zones (AZs) to deploy the production VPC and Transit Gateway (TGW) attachment into."
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "private_subnets" {
  description = "Transit Gateway (TGW) attachment subnets, one per Availability Zone (AZ)."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.20.0/24", "10.20.110.0/24"]
}

variable "tags" {
  description = "Tags applied to all resources in this account"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Environment = "production"
    Service     = "production"
  }
}

variable "networking_enabled" {
  description = <<-EOT
    Master switch for the billable networking layer in this account.
    Setting this to false stops the spend; the account, its OpenID
    Connect (OIDC) roles, its state file, and its Systems Manager (SSM)
    entries all survive. This is a pause, not a teardown.

    ORDERING: production and development must both be applied with this
    set to false BEFORE the network account is flipped. The Transit
    Gateway (TGW) cannot be deleted while spoke attachments still exist.
  EOT
  type        = bool
  default     = true
}
