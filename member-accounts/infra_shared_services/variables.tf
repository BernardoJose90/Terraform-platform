variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "tags" {
  description = "Tags applied to all resources in this account"
  type        = map(string)
  default = {
    ManagedBy   = "TerraformS"
    Environment = "infra-shared-services"
    Service     = "infra-shared-services"
  }
}
