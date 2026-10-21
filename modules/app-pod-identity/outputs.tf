# ======================================================================================
# modules/app-pod-identity/outputs.tf
#
# This is the module's public interface, consumed by whichever account
# calls it. Renaming or removing anything here is a breaking change for
# the callers.
# ======================================================================================

output "role_arn" {
  description = "ARN of the Pod Identity role."
  value       = module.pod_identity.iam_role_arn
}

output "role_name" {
  description = "Name of the Pod Identity role."
  value       = module.pod_identity.iam_role_name
}
