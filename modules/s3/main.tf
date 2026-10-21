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
#   - Server-side encryption (SSE-KMS, AWS-managed aws/s3 key).
#   - Versioning, so an accidental overwrite or delete isn't permanent.
#   - Aborting incomplete multipart uploads after 7 days, so an
#     abandoned/crashed upload doesn't quietly keep costing storage.
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

  # KMS (AWS-managed aws/s3 key, no kms_master_key_id set) rather than
  # SSE-S3/AES256 — same reasoning and same "no new customer key needed"
  # approach as modules/ecr's repository_encryption_type.
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "aws:kms"
      }
    }
  }

  lifecycle_rule = concat(
    var.expiration_days == null ? [] : [
      {
        id      = "expire-objects"
        enabled = true

        expiration = {
          days = var.expiration_days
        }
      }
    ],
    [
      # Unconditional, not exposed as a variable — same "no legitimate
      # reason to turn this off" reasoning as versioning/encryption
      # above. Cleans up storage silently consumed by multipart uploads
      # that started but never completed or got aborted (a crashed
      # upload, a client that gave up partway through).
      {
        id      = "abort-incomplete-multipart-uploads"
        enabled = true

        abort_incomplete_multipart_upload_days = 7
      }
    ]
  )

  tags = var.tags
}
