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

# EKS cluster is a separate, billable resource that can be paused
# independently of the networking layer. This is useful for development
# outside working hours, when the cluster isn't needed but the VPC and
# its subnets are still useful for other things (e.g. a bastion host or
# a VPN endpoint).
variable "eks_enabled" {
  description = <<-EOT
    Switch for the EKS cluster specifically, independent of
    networking_enabled — the VPC and dev_purpose_subnets stay up when
    this is false, only the cluster (and its control-plane cost) goes
    away. Meant for pausing EKS outside working hours without tearing
    down the rest of the account.

    ANYTHING ADDED LATER THAT DEPENDS ON THE CLUSTER EXISTING — IRSA
    roles, an ALB controller, cluster add-ons, Pod Identity associations
    — must be gated on the same condition
    (var.networking_enabled && var.eks_enabled), the way module.eks
    itself is in main.tf, or reference it through a count/for_each-safe
    accessor (e.g. one(module.eks[*].x)) instead of module.eks[0]
    directly. Otherwise turning this off would break their plan instead
    of cleanly deleting them.
  EOT
  type        = bool
  default     = true
}

variable "eks_endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the EKS cluster's public Kubernetes API
    endpoint, e.g. ["203.0.113.4/32"] for a single IP. No default on
    purpose — modules/eks refuses to apply with public access on and
    this left empty, rather than silently falling back to something
    permissive.

    This is an interim access path: it exists until Argo CD and
    break-glass access are in place, at which point the plan is to move
    the endpoint to private-only (see modules/eks/variables.tf). It's
    also fragile against CI specifically — GitHub-hosted runners get a
    different egress IP on every run, so nothing in deploy-plan.yaml or
    deploy-apply.yaml can rely on reaching the cluster's Kubernetes API
    through this endpoint the way it can reach the EKS control-plane API
    (which doesn't go through this CIDR restriction at all).
  EOT
  type        = list(string)
  default     = []
}
