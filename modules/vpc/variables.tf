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

# ======================================================================================
# Naming overrides. All optional — if left empty, the upstream module falls back to its
# own generated names (var.name + a suffix). Only private_subnet_names/public_subnet_names/
# igw_tags are exposed here because they're the only ones the upstream module supports as
# a per-index list — NAT gateways and per-AZ route tables only take a single flat tags map
# (nat_gateway_tags, private_route_table_tags), which can't assign a DIFFERENT name to each
# one. Callers that need exact, differentiated names for those (e.g. "nat-egress-a" vs
# "nat-egress-b") do it themselves with aws_ec2_tag against the natgw_ids/
# private_route_table_ids outputs below — see member-accounts/network/main.tf.
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
# VPC Flow Logs. On by default for every caller — CloudWatch Logs destination, with the
# upstream module creating both the log group and the IAM role that delivers to it.
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
