# ======================================================================================
# Input variables for the shared RDS module. Only what genuinely differs
# per account is exposed here — see main.tf's header comment for what's
# deliberately hardcoded instead and why.
# ======================================================================================

variable "identifier" {
  description = "RDS instance identifier, e.g. \"event-network-hub\"."
  type        = string
}

variable "db_name" {
  description = "Name of the initial database created inside the instance."
  type        = string
}

variable "username" {
  description = "Master username. The password itself is never set here — see main.tf's header comment on manage_master_user_password."
  type        = string
  default     = "postgres"
}

variable "vpc_id" {
  description = "VPC to create the instance's security group in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group. Must span at least 2 AZs — RDS requires this even for a single-AZ instance."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must span at least 2 AZs — RDS requires a DB subnet group to cover 2+ AZs even when multi_az is false."
  }
}

variable "allowed_security_group_id" {
  description = "Security group allowed to connect on the Postgres port — this cluster's EKS node security group (module.eks.node_security_group_id), not a broader CIDR."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class, e.g. \"db.t4g.small\" for dev, \"db.t4g.medium\" (or larger) for production."
  type        = string
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Multi-AZ automatic failover to a standby. false for dev, true for production."
  type        = bool
}

variable "backup_retention_period" {
  description = "Automated backup retention in days — a few days for dev, 7-35 for production."
  type        = number
}

variable "deletion_protection" {
  description = "Block this instance from being deleted (by Terraform, the console, or the CLI). Optional for dev, on for production."
  type        = bool
}

variable "skip_final_snapshot" {
  description = "Skip taking a final snapshot on deletion. true is reasonable for dev (convenience); false for production (never delete real data without a snapshot first)."
  type        = bool
}

variable "tags" {
  description = "Tags applied to the instance and the resources this module creates."
  type        = map(string)
  default     = {}
}
