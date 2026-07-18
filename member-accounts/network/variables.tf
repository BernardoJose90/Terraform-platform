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