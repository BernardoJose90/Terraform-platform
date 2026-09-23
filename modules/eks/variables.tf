# ======================================================================================
# Input variables for the shared EKS module. Only what genuinely differs
# per account is exposed here — see main.tf's header comment for what's
# deliberately hardcoded instead and why.
# ======================================================================================

variable "name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the control plane and, by default, every managed node group."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the cluster's security groups in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the control plane's cross-account ENIs, and the default subnets for every managed node group (a group can override this — see var.node_groups). One per AZ."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must span at least 2 AZs — a single-AZ cluster has no fault tolerance if that AZ has an outage. 3 AZs is the stronger choice for production, where the region has one to spare."
  }
}

# ======================================================================================
# Endpoint access. The private endpoint is always on (see main.tf) — this
# only controls the public side.
# ======================================================================================
variable "endpoint_public_access" {
  description = "Expose the cluster's Kubernetes API endpoint publicly, restricted to endpoint_public_access_cidrs. Treat true as an interim state: it's needed until you have an in-VPC access path (a bastion, SSM Session Manager, or a runner inside the VPC), at which point this should switch to false."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public endpoint when endpoint_public_access = true. No default on purpose — the upstream module's own default is 0.0.0.0/0, and inheriting that silently would defeat the point of restricting it at all."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.endpoint_public_access || length(var.endpoint_public_access_cidrs) > 0
    error_message = "endpoint_public_access_cidrs must list specific CIDRs when endpoint_public_access = true, e.g. [\"203.0.113.4/32\"]."
  }

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "endpoint_public_access_cidrs may not include 0.0.0.0/0 — that opens the API server to the entire internet, which defeats the point of restricting it. Set endpoint_public_access = false instead if you need broader-than-one-IP access."
  }
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention for the control plane's CloudWatch log group. All 5 log types are always enabled (see main.tf) — this only controls how long they're kept."
  type        = number
  default     = 90
}

# ======================================================================================
# Access control. authentication_mode is always "API" (see main.tf) — EKS
# access entries, not the aws-auth ConfigMap.
# ======================================================================================
variable "enable_cluster_creator_admin_permissions" {
  description = "Grant the identity running Terraform (e.g. the TerraformDeploy role during a CI apply) cluster-admin via an access entry. Usually needed at least once, since something has to be able to grant every other access_entries entry in the first place."
  type        = bool
  default     = true
}

variable "access_entries" {
  description = "Additional IAM principals to grant Kubernetes access, keyed arbitrarily. Same shape as the upstream module's own access_entries variable: https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/variables.tf"
  type        = any
  default     = {}
}

# ======================================================================================
# Add-ons. vpc-cni, eks-pod-identity-agent, kube-proxy, and coredns are
# always installed (see main.tf) — these two are optional on top of that.
# ======================================================================================
variable "enable_metrics_server" {
  description = "Install the metrics-server addon (needed for `kubectl top` and Horizontal Pod Autoscalers)."
  type        = bool
  default     = true
}

variable "enable_node_monitoring_agent" {
  description = "Install the eks-node-monitoring-agent addon, matching the console-built cluster. Powers node health detection; pair with a node group's own node_repair_config for auto-repair, which this module leaves off by default."
  type        = bool
  default     = true
}

# ======================================================================================
# Managed node groups.
# ======================================================================================
variable "node_groups" {
  description = <<-EOT
    Managed node groups, keyed by an arbitrary name (e.g. "general").
    Every group gets these fixed, non-overridable defaults (see main.tf):
    IMDSv2 required, an encrypted EBS root volume, and no
    AmazonEKS_CNI_Policy on the node role — CNI permissions come only
    from the dedicated Pod Identity role this module creates
    (module.vpc_cni_pod_identity), not the node role.
  EOT
  type = map(object({
    subnet_ids     = optional(list(string)) # falls back to var.subnet_ids
    instance_types = optional(list(string), ["m6i.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    disk_size      = optional(number, 50)
    min_size       = number
    max_size       = number
    desired_size   = number
    labels         = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
  }))

  validation {
    condition     = alltrue([for g in values(var.node_groups) : g.min_size <= g.desired_size && g.desired_size <= g.max_size])
    error_message = "Every node group needs min_size <= desired_size <= max_size."
  }
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}
