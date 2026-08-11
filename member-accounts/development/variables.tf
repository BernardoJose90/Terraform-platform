variable "aws_region" {
  description = "AWS region to deploy the production environment into."
  type        = string
  default     = "eu-west-2"

}

variable "cidr" {
  description = "CIDR block for the development VPC"
  type        = string
  default     = "10.30.0.0/16"
}

variable "azs" {
  description = "AZs to deploy the development VPC and TGW attachment into"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "private_subnets" {
  description = "TGW-attachment subnets, one per AZ"
  type        = list(string)
  default     = ["10.30.10.0/24", "10.30.20.0/24"]
}

variable "tags" {
  description = "Tags applied to all resources in this account"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Environment = "development"
    Service     = "development"
  }
}

variable "networking_enabled" {
  description = <<-EOT
    Master switch for the billable networking layer in this account.
    False stops spend; the account, its OIDC roles, its state file and
    its SSM entries all survive. This is a pause, not a teardown.

    ORDERING: production AND development must both be applied with false
    BEFORE the network account is flipped. The TGW cannot be deleted while
    spoke attachments exist.
  EOT
  type        = bool
  default     = true
}
