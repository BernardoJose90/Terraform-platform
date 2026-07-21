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

variable "cidr" {
  description = "value"
  type = string
}

variable "azs" {
  description = "AZs"
  type = list()
}
variable "private_subnets" {
  description = "private subnets"
  type = list()
}

variable "public_subnets" {
  description = "public subnets"
  type = list()
}
