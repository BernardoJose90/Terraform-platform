output "tgw_attachment_id" {
  description = "TGW VPC attachment ID — consumed by the network account via terraform_remote_state"
  value       = module.tgw_attachment.attachment_id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}
