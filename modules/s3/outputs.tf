# ======================================================================================
# modules/s3/outputs.tf
#
# This is the module's public interface, consumed by whichever account
# calls it. Renaming or removing anything here is a breaking change for
# the callers.
# ======================================================================================

output "bucket_id" {
  description = "Bucket name (same as var.bucket_name, but also the resource's actual ID)."
  value       = module.bucket.s3_bucket_id
}

output "bucket_arn" {
  description = "ARN of the bucket. Scope an app's Pod Identity role's s3:GetObject/PutObject/ListBucket permissions to exactly this ARN (and this ARN + \"/*\" for object-level actions) — never a wildcard across every bucket."
  value       = module.bucket.s3_bucket_arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name for building an S3 URL/endpoint."
  value       = module.bucket.s3_bucket_bucket_regional_domain_name
}
