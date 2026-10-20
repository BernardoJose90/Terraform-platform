# ======================================================================================
# modules/ecr/outputs.tf
#
# This is the module's public interface, consumed by whichever account
# calls it. Renaming or removing anything here is a breaking change for
# the callers.
# ======================================================================================

output "repository_name" {
  description = "Repository name."
  value       = module.ecr.repository_name
}

output "repository_arn" {
  description = "ARN of the repository — use this to scope a push role's IAM permissions to exactly this repository, never a wildcard across the registry."
  value       = module.ecr.repository_arn
}

output "repository_url" {
  description = "Full repository URI for docker push/pull, e.g. <account>.dkr.ecr.<region>.amazonaws.com/<name>."
  value       = module.ecr.repository_url
}
