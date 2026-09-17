variable "vpc_id" {
  description = "Virtual Private Cloud (VPC) to create these subnets in."
  type        = string
}

variable "tgw_id" {
  description = "Transit Gateway (TGW) ID. Only needed if at least one purpose has to_tgw = true — leave null if none do (this is validated below)."
  type        = string
  default     = null
}

variable "production_workload_subnets" {
  description = <<-EOT
    One entry per purpose-specific subnet group (e.g. "eks", "rds"). Each
    group gets its own route table, shared across every Availability Zone
    (AZ) listed in its subnets map — not one table per AZ. Unlike a NAT
    gateway, a Transit Gateway (TGW) attachment is a single logical target
    no matter which AZ traffic comes from, so there's no need for a
    separate target per AZ. One shared table per purpose is simpler and
    equally correct.

    to_tgw controls whether that purpose's route table gets a
    0.0.0.0/0 -> Transit Gateway route at all. Set it to true only for
    purposes that actually need to initiate outbound traffic (e.g. EKS
    worker nodes pulling container images). A database tier or an internal
    load balancer typically shouldn't have one.
  EOT
  type = map(object({
    route_table_name = string
    to_tgw           = bool
    subnets = map(object({
      az   = string
      cidr = string
      name = string
    }))
  }))

  validation {
    condition     = !anytrue([for p in var.production_workload_subnets : p.to_tgw]) || var.tgw_id != null
    error_message = "At least one purpose has to_tgw = true, so tgw_id must be set."
  }
}

variable "tags" {
  description = "Tags applied to every subnet and route table that this module creates."
  type        = map(string)
  default     = {}
}
