# ======================================================================================
# Input variables for the shared VPC module.
#
# Some of the validation blocks below compare one variable's value against
# another. That kind of check needs Terraform 1.9 or later (see
# required_version in main.tf).
#
# Where to add a new check:
#   - if it only compares variables to each other, add a validation block
#     here
#   - if it needs a resource or module output (something not known until
#     apply time), add a precondition block in main.tf instead
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

  # Each spoke account's own main.tf creates a default route (0.0.0.0/0)
  # to the Transit Gateway, and matches it to a private route table by
  # position in this list. That matching only works correctly if there is
  # exactly one private subnet per Availability Zone (AZ, an isolated
  # physical data center location within an AWS region).
  validation {
    condition     = length(var.private_subnets) == length(var.azs)
    error_message = "private_subnets and azs must be the same length (one private subnet per AZ)."
  }
}

variable "public_subnets" {
  description = "Public subnet CIDRs. Empty for spoke VPCs, which are fully private."
  type        = list(string)
  default     = []

  # The upstream module places NAT gateways into public subnets. Turning
  # NAT on without defining any public subnets would only fail later, at
  # apply time, after the VPC already exists. This check catches that
  # mistake earlier instead.
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
  description = "Transit Gateway ID for a spoke VPC. This module doesn't create the route itself — the caller adds the 0.0.0.0/0-to-TGW route in its own main.tf. Passed here only so the validation blocks below can confirm the caller declared a coherent egress setup. Leave null for the egress VPC or a deliberately isolated VPC."
  type        = string
  default     = null

  # Setting enable_nat_gateway = true makes the upstream module write a
  # default route (0.0.0.0/0) through NAT into the private route tables.
  # Setting a non-null tgw_id means the caller will later write its own
  # default route to the Transit Gateway into those same tables. AWS only
  # allows one default route per route table, so doing both would fail
  # partway through apply with a "RouteAlreadyExists" error — leaving a
  # half-built VPC behind, with NAT gateways already running (and already
  # costing money).
  validation {
    condition     = !(var.tgw_id != null && var.enable_nat_gateway)
    error_message = "tgw_id and enable_nat_gateway are mutually exclusive — each drives a 0.0.0.0/0 route into the same private route tables."
  }

  # This check is a deliberate policy choice, not a safety guard against
  # breakage: it insists every VPC built by this module has some way to
  # reach the internet, unless the caller explicitly opts out by setting
  # allow_no_default_route = true for a deliberately isolated VPC. Today,
  # production sets tgw_id, network sets enable_nat_gateway, and
  # development sets the opt-out while it's temporarily detached from the
  # Transit Gateway.
  validation {
    condition     = var.tgw_id != null || var.enable_nat_gateway || var.allow_no_default_route
    error_message = "Set tgw_id (spoke VPC), enable_nat_gateway (egress VPC), or allow_no_default_route (deliberately isolated). Otherwise private subnets have no default route to anywhere."
  }
}

variable "allow_no_default_route" {
  description = "Permit a VPC with no default route at all — no tgw_id, no NAT. For a deliberately isolated VPC (e.g. development while detached from the Transit Gateway). Leave false for a normal spoke or egress VPC."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

# ======================================================================================
# Optional name overrides. Leave these empty and the upstream module just
# uses its own auto-generated names. Only the three below can be set as a
# list with one name per Availability Zone. NAT gateways and route tables
# each only accept a single flat map of tags, so giving those per-AZ
# names has to be done separately by the caller, using the aws_ec2_tag
# resource (see member-accounts/network).
# ======================================================================================
variable "private_subnet_names" {
  description = "Explicit Name tag per private subnet, same order as var.azs. Leave empty to use the upstream module's generated names."
  type        = list(string)
  default     = []
}

variable "public_subnet_names" {
  description = "Explicit Name tag per public subnet, same order as var.azs. Leave empty to use the upstream module's generated names."
  type        = list(string)
  default     = []
}

variable "igw_tags" {
  description = "Additional tags for the Internet Gateway (e.g. { Name = \"igw-egress\" })."
  type        = map(string)
  default     = {}
}

# ======================================================================================
# VPC Flow Logs — records of network traffic in and out of the VPC — are
# on by default for every account that uses this module. They're sent to
# CloudWatch Logs, and the upstream module creates both the log group and
# the IAM role that delivers logs into it.
# ======================================================================================
variable "enable_flow_log" {
  description = "Enable VPC Flow Logs for this VPC. On by default so every account using this module gets flow logs without opting in."
  type        = bool
  default     = true
}

variable "flow_log_traffic_type" {
  description = "Type of traffic to capture: ACCEPT, REJECT, or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be one of: ACCEPT, REJECT, ALL."
  }
}

variable "flow_log_cloudwatch_log_group_retention_in_days" {
  description = "Retention for the auto-created CloudWatch log group that flow logs are delivered to."
  type        = number
  default     = 90
}

variable "flow_log_max_aggregation_interval" {
  description = "Max interval (seconds) at which flow log records are aggregated: 60 or 600."
  type        = number
  default     = 600
}
