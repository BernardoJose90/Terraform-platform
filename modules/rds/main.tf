# ======================================================================================
# Shared RDS (PostgreSQL) module. Wraps terraform-aws-modules/rds/aws the
# same way modules/eks wraps terraform-aws-modules/eks/aws: one local
# module that bakes in this platform's own security baseline, so every
# account that runs a database gets it automatically instead of having to
# remember to configure it by hand each time.
#
# Baked in here, not exposed as variables, because there's no legitimate
# reason for a caller to turn them off:
#   - manage_master_user_password = true. RDS generates the master
#     password itself and stores it as an auto-rotated AWS Secrets
#     Manager secret — it never touches Terraform state or a .tfvars
#     file. Given both of this org's Terraform repos are public, a
#     plain `password` input isn't optional here.
#   - storage_encrypted = true.
#   - publicly_accessible = false. This instance is only ever reachable
#     from inside the VPC, via the security group below — never the
#     internet, regardless of how the EKS cluster's own public endpoint
#     is configured. Those are two unrelated gates.
#   - engine = "postgres", engine_version = "17" — the same engine
#     version in every account on purpose (see the caller's own
#     comment), so this isn't exposed as a variable to accidentally
#     drift per account. Revisit by changing it here, not per-caller,
#     if that ever needs to change.
#
# What IS exposed (variables.tf) is what genuinely differs per account:
# instance size, Multi-AZ, backup retention, deletion protection, and
# final-snapshot behavior.
# ======================================================================================

resource "aws_security_group" "rds" {
  name        = "${var.identifier}-rds"
  description = "Allows Postgres (5432) only from this cluster's own EKS node security group — no broader CIDR."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from the EKS node security group"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id]
  }

  # No egress block: this database should never be able to start an
  # outbound connection of its own, to anything — same reasoning as the
  # rds subnet group's own route table never getting a route out.

  tags = var.tags
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.2"

  identifier = var.identifier

  engine               = "postgres"
  engine_version       = "17"
  family               = "postgres17"
  major_engine_version = "17"

  db_name  = var.db_name
  username = var.username

  manage_master_user_password = true

  port = 5432

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage

  storage_encrypted = true

  multi_az               = var.multi_az
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds.id]

  create_db_subnet_group = true
  subnet_ids             = var.subnet_ids

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot

  create_db_parameter_group = false

  tags = var.tags
}
