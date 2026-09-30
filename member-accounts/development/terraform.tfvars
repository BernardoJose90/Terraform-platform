aws_region = "eu-west-2"

# VPC Configuration
cidr            = "10.30.0.0/16"
azs             = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
private_subnets = ["10.30.10.0/24", "10.30.20.0/24", "10.30.30.0/24"]

# Development runs as a standalone, isolated VPC for now — detached from the
# Transit Gateway. No egress, no cross-account routing, no dependency on the
# network account. Set true (with the network account applied) to reattach.
tgw_attachment_enabled = true

# eks_enabled's own default in variables.tf is false (left that way by the
# "delete dev eks" commit) — explicit here so the cluster we're actively
# rebuilding doesn't get destroyed on the next apply.
eks_enabled = true

eks_endpoint_public_access_cidrs = ["31.205.10.9/32"]
