variable "aws_region" {
  description = "AWS region to deploy the production environment into."
  type        = string
  default     = "eu-west-2"

}

variable "cidr" {
  description = "CIDR block for the production VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "AZs to deploy the production VPC and TGW attachment into"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "private_subnets" {
  description = "TGW-attachment subnets, one per AZ"
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.20.0/24"]
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
