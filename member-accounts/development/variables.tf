variable "aws_region" {
  description = "AWS region to deploy the production environment into."
  type        = string
  default     = "eu-west-2"

}

variable "cidr" {
  description = "The IP address range (in CIDR notation, e.g. 10.30.0.0/16) for the development Virtual Private Cloud (VPC)"
  type        = string
  default     = "10.30.0.0/16"
}

variable "azs" {
  description = "Availability Zones (AZs — separate, isolated data center locations within the AWS region) to deploy the development VPC and its Transit Gateway (TGW) attachment into"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "private_subnets" {
  description = "The subnets used for the Transit Gateway (TGW) attachment, one per Availability Zone"
  type        = list(string)
  default     = ["10.30.10.0/24", "10.30.20.0/24"]
}

variable "tags" {
  description = "Tags applied to all resources in this account"
  type        = map(string)
  default = {
    ManagedBy   = "TerraformS"
    Environment = "development"
    Service     = "development"
  }
}

variable "networking_enabled" {
  description = <<-EOT
    Master on/off switch for the networking resources in this account
    that actually cost money (the VPC). Setting this to false stops that
    spend, while the account itself, its CI/CD (OIDC) roles, its
    Terraform state file, and its SSM Parameter Store entries all stay in
    place. This is a pause, not a full teardown.

    ORDERING: both the production and development accounts must be
    applied with this set to false BEFORE the network account is
    switched off. The Transit Gateway (TGW) cannot be deleted while the
    spoke accounts still have active attachments to it.
  EOT
  type        = bool
  default     = true
}

variable "tgw_attachment_enabled" {
  description = <<-EOT
    Wires this account's VPC into the network account's Transit Gateway
    (TGW). This is independent of networking_enabled, which controls
    whether the VPC itself exists at all.

    Set this to false to run development as a standalone, fully isolated
    VPC: no TGW attachment, no cross-account routing, and no dependency
    on the network account being applied. The attachment and routing code
    stays in main.tf either way — just flip this back to true and
    re-apply to reattach.
  EOT
  type        = bool
  default     = true
}
