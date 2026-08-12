variable "vpc_id" {
  description = "VPC to create these subnets in."
  type        = string
}

variable "tgw_id" {
  description = "Transit Gateway ID. Only needed if at least one purpose has to_tgw = true — leave null if none do (validated below)."
  type        = string
  default     = null
}

variable "purposes" {
  description = <<-EOT
    One entry per purpose-specific subnet group (e.g. "eks", "rds"). Each
    gets its own route table, shared across every AZ listed in its
    subnets map — not one table per AZ. There's no per-AZ target here
    the way a NAT gateway would force one (a Transit Gateway attachment
    is a single logical target either way), so one shared table per
    purpose is simpler and equally correct.

    to_tgw controls whether that purpose's route table gets a
    0.0.0.0/0 -> Transit Gateway route at all. Set true only for
    purposes that actually need to initiate outbound traffic (e.g. EKS
    worker nodes pulling images) — a database tier or an internal load
    balancer typically shouldn't have one.
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
    condition     = !anytrue([for p in var.purposes : p.to_tgw]) || var.tgw_id != null
    error_message = "At least one purpose has to_tgw = true, so tgw_id must be set."
  }
}

variable "tags" {
  description = "Tags applied to every subnet and route table this module creates."
  type        = map(string)
  default     = {}
}
