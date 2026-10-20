# ======================================================================================
# modules/rds/outputs.tf
#
# This is the module's public interface, consumed by whichever account
# calls it. Renaming or removing anything here is a breaking change for
# the callers.
# ======================================================================================

output "db_instance_identifier" {
  description = "RDS instance identifier."
  value       = module.db.db_instance_identifier
}

output "db_instance_arn" {
  description = "ARN of the RDS instance."
  value       = module.db.db_instance_arn
}

output "db_instance_endpoint" {
  description = "Connection endpoint, host:port."
  value       = module.db.db_instance_endpoint
}

output "db_instance_address" {
  description = "Hostname only, no port — for building a DATABASE_URL."
  value       = module.db.db_instance_address
}

output "db_instance_port" {
  description = "Port the instance listens on."
  value       = module.db.db_instance_port
}

output "master_user_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret RDS created and manages for the master password. Grant an app's Pod Identity role secretsmanager:GetSecretValue scoped to exactly this ARN — never a static, Terraform-held password."
  value       = module.db.db_instance_master_user_secret_arn
}

output "security_group_id" {
  description = "ID of the security group this module created for the instance."
  value       = aws_security_group.rds.id
}
