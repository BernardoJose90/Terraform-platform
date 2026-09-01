aws_region = "eu-west-2"

# VPC Configuration
cidr            = "10.30.0.0/16"
azs             = ["eu-west-2a", "eu-west-2b"]
private_subnets = ["10.30.10.0/24", "10.30.20.0/24"]

# Development runs as a standalone, isolated VPC for now — detached from the
# Transit Gateway. No egress, no cross-account routing, no dependency on the
# network account. Set true (with the network account applied) to reattach.
tgw_attachment_enabled = false
