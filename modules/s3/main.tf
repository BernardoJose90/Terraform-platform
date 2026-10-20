# ======================================================================================
# Shared S3 module. Wraps terraform-aws-modules/s3-bucket/aws the same
# way modules/eks and modules/rds wrap their own upstream modules: one
# local module that bakes in this platform's own security baseline, so
# every bucket this platform creates gets it automatically instead of
# having to remember to configure it by hand each time.
#
# For a fully private, app-only bucket — read/written only by the app
# itself via its own Pod Identity role, never served or listed directly
# to end users. If a future use case needs public-read access (e.g.
# serving images directly from S3/a CDN), that's a different, more
# permissive module — don't repurpose this one by adding a toggle to
# turn its public access block off.
#
# Baked in here, not exposed as variables, because there's no legitimate
# reason for a caller to turn them off:
#   - All four public access block settings. This is actually the
#     upstream module's own default (true) — we just don't override it
#     away, and set it explicitly so it's not silently relying on
#     upstream's default remaining what it is today.
#   - Server-side encryption (SSE-S3/AES256).
#   - Versioning, so an accidental overwrite or delete isn't permanent.
#
# What IS exposed (variables.tf) is what genuinely differs per bucket:
# its name, whether Terraform is allowed to force-delete it, and how
# long (if at all) objects should be auto-expired.
# ======================================================================================

module "bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.17"

  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = {
    status = "Enabled"
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = var.expiration_days == null ? [] : [
    {
      id      = "expire-objects"
      enabled = true

      expiration = {
        days = var.expiration_days
      }
    }
  ]

  tags = var.tags
}
