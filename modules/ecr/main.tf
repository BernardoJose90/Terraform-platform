# ======================================================================================
# Shared ECR module. Wraps terraform-aws-modules/ecr/aws the same way
# modules/eks, modules/rds, and modules/s3 wrap their own upstream
# modules: one local module that bakes in this platform's own security
# baseline, so every repository this platform creates gets it
# automatically instead of having to remember to configure it by hand
# each time.
#
# Meant to live in a shared-services account (e.g. infra_shared_services)
# with other accounts pulling cross-account — not one repository per
# account. Build once, promote the same image through environments,
# rather than rebuilding per account.
#
# Baked in here, not exposed as variables, because there's no legitimate
# reason for a caller to turn them off:
#   - repository_image_tag_mutability = "IMMUTABLE". Once a tag is
#     pushed, it can't be silently overwritten — the same tag always
#     resolves to the same image, which is what makes "promote this
#     exact image from dev to prod" a meaningful, trustworthy operation.
#   - repository_image_scan_on_push = true. Every image gets scanned for
#     known vulnerabilities automatically; nothing to opt into per push.
#   - Encryption at rest (AES256).
#
# What IS exposed (variables.tf) is what genuinely differs per
# repository: its name, which accounts can pull, which one role can
# push, and how long untagged images are kept before being expired.
# ======================================================================================

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = var.repository_name

  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true
  repository_encryption_type      = "AES256"

  repository_read_access_arns = [
    for account_id in var.read_access_account_ids : "arn:aws:iam::${account_id}:root"
  ]

  repository_read_write_access_arns = var.push_role_arn == null ? [] : [var.push_role_arn]

  create_lifecycle_policy = true
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = { type = "expire" }
      }
    ]
  })

  tags = var.tags
}
