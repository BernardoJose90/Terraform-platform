# ======================================================================================
# Input variables for the shared VPC module.
#
# The validation blocks below use cross-variable references (Terraform 1.9+).
# See required_version in main.tf.
#
# Rule of thumb for where a check goes:
#   - compares variables only          -> validation block here
#   - needs a resource/module output   -> precondition block in main.tf
# ======================================================================================

variable "name" {
  description = "Name prefix for the VPC and its subnets, route tables, etc."
  type        = string
}

variable "cidr" {
  description = "CIDR block for the VPC, e.g. 10.30.0.0/16. Must not overlap any other account's VPC — TGW routing breaks on overlapping ranges."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be valid CIDR notation, e.g. 10.30.0.0/16."
  }
}

variable "azs" {
  description = "Availability zones to spread subnets across, e.g. [\"eu-west-2a\", \"eu-west-2b\"]."
  type        = list(string)

  validation {
    condition     = length(var.azs) > 0
    error_message = "At least one availability zone is required."
  }
}

variable "private_subnets" {
  description = "Private subnet CIDRs, one per AZ, in the same order as var.azs."
  type        = list(string)

  # The aws_route.private_to_tgw resource maps AZ position to private route table
  # position. That mapping only holds if these two lists are the same length.
  validation {
    condition     = length(var.private_subnets) == length(var.azs)
    error_message = "private_subnets and azs must be the same length (one private subnet per AZ)."
  }
}

variable "public_subnets" {
  description = "Public subnet CIDRs. Empty for spoke VPCs, which are fully private."
  type        = list(string)
  default     = []

  # NAT gateways are placed in public subnets by the upstream module. Enabling NAT
  # without any public subnets fails at apply, after the VPC already exists.
  validation {
    condition     = !var.enable_nat_gateway || length(var.public_subnets) > 0
    error_message = "enable_nat_gateway requires at least one public subnet — NAT gateways must be placed in public subnets."
  }
}

variable "enable_nat_gateway" {
  description = "Set true only for the network account's NAT/egress VPC"
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Place a single NAT gateway for the whole VPC. Cheaper, but a single point of failure, and it collapses the private route tables to one."
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "Place one NAT gateway in each AZ. Higher availability, higher cost."
  type        = bool
  default     = false

  validation {
    condition     = !(var.one_nat_gateway_per_az && var.single_nat_gateway)
    error_message = "one_nat_gateway_per_az and single_nat_gateway are mutually exclusive — pick one NAT strategy."
  }
}

variable "tgw_id" {
  description = "If set, adds a 0.0.0.0/0 route from private subnets to this TGW (spoke VPCs)"
  type        = string
  default     = null

  # Both paths write a 0.0.0.0/0 route into the same private route tables. AWS allows
  # only one default route per table, so the second call fails with RouteAlreadyExists
  # — at apply, leaving a half-built VPC with NAT gateways already billing.
  validation {
    condition     = !(var.tgw_id != null && var.enable_nat_gateway)
    error_message = "tgw_id and enable_nat_gateway are mutually exclusive — both write a 0.0.0.0/0 route to the private route tables."
  }

  # POLICY CHECK, not a safety check. This asserts that every VPC built from this
  # module has an egress path. Correct for the current three accounts, but it would
  # block a deliberately isolated VPC. Delete this block if you ever want one.
  validation {
    condition     = var.tgw_id != null || var.enable_nat_gateway
    error_message = "Set either tgw_id (spoke VPC) or enable_nat_gateway (egress VPC). Neither means private subnets have no default route to anywhere."
  }
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}
