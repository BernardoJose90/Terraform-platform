# ======================================================================================
# Input variables for the shared app Pod Identity module. Everything here
# genuinely differs per app/account — there's nothing to bake in, unlike
# modules/rds, modules/s3, and modules/ecr, since this module has no
# security baseline of its own to enforce; it's purely a thin wrapper
# around "one app's own IAM role, bound to one Kubernetes service
# account."
# ======================================================================================

variable "name" {
  description = "Name for the Pod Identity role, e.g. \"event-network-hub-app\"."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster this app's pods run in."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the app's service account lives in."
  type        = string
}

variable "service_account" {
  description = "Kubernetes service account this role is bound to — an exact string match against what the app's own manifests actually deploy."
  type        = string
}

variable "policy_statements" {
  description = "IAM policy statements granting this app's actual AWS permissions (e.g. secretsmanager:GetSecretValue on an RDS secret, s3:GetObject/PutObject on a bucket). Empty by default — a role with no permissions attached, for scaffolding a Pod Identity association before the resources it needs to access exist yet."
  type = list(object({
    sid           = optional(string)
    actions       = optional(list(string))
    not_actions   = optional(list(string))
    effect        = optional(string)
    resources     = optional(list(string))
    not_resources = optional(list(string))
    principals = optional(list(object({
      type        = string
      identifiers = list(string)
    })))
    not_principals = optional(list(object({
      type        = string
      identifiers = list(string)
    })))
    condition = optional(list(object({
      test     = string
      values   = list(string)
      variable = string
    })))
  }))
  default = []
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
