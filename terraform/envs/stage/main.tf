provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Environment = var.env
    Project     = "invoice-doc-storage"
    Owner       = "platform-team"
    CostCenter  = var.cost_center
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Networking (no deps)
# -----------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  env        = var.env
  vpc_cidr   = var.vpc_cidr
  az_count   = var.az_count
  aws_region = var.aws_region
  tags       = local.common_tags
}

# -----------------------------------------------------------------------------
# KMS (no deps — root account admin delegates to IAM policies)
# -----------------------------------------------------------------------------
module "kms" {
  source = "../../modules/kms"

  env            = var.env
  aws_account_id = var.aws_account_id
  tags           = local.common_tags
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL (depends on: networking, kms)
# -----------------------------------------------------------------------------
module "aurora_postgres" {
  source = "../../modules/aurora_postgres"

  env                         = var.env
  kms_key_arn                 = module.kms.key_arn
  data_subnet_ids             = module.networking.data_subnet_ids
  sg_aurora_id                = module.networking.sg_aurora_id
  instance_class              = var.aurora_instance_class
  instance_count              = var.aurora_instance_count
  backup_retention_days       = var.aurora_backup_retention_days
  enable_performance_insights = var.enable_performance_insights
  deletion_protection         = var.aurora_deletion_protection
  enable_rds_proxy            = var.enable_rds_proxy
  tags                        = local.common_tags
}

# -----------------------------------------------------------------------------
# Monitoring (depends on: kms, aurora)
# SNS topic must be created before S3 notification can reference it.
# -----------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  env                    = var.env
  aws_account_id         = var.aws_account_id
  aws_region             = var.aws_region
  aurora_cluster_id      = module.aurora_postgres.cluster_id
  s3_bucket_name         = "invoice-docs-${var.env}"
  kms_key_id             = module.kms.key_id
  kms_key_arn            = module.kms.key_arn
  alert_email            = var.alert_email
  log_retention_days     = var.log_retention_days
  aurora_max_connections = var.aurora_max_connections
  tags                   = local.common_tags
}

# -----------------------------------------------------------------------------
# S3 Documents (depends on: kms, monitoring for SNS topic)
# -----------------------------------------------------------------------------
module "s3_documents" {
  source = "../../modules/s3_documents"

  env                        = var.env
  kms_key_arn                = module.kms.key_arn
  enable_object_lock         = var.enable_object_lock
  object_lock_retention_days = var.object_lock_retention_days
  notification_sns_topic_arn = module.monitoring.sns_topic_arn
  tags                       = local.common_tags
}

# -----------------------------------------------------------------------------
# Transfer Family SFTP (depends on: kms, monitoring)
# Vendors drop files via SFTP → landing zone bucket → SNS → Lambda
# -----------------------------------------------------------------------------
module "transfer_family" {
  source = "../../modules/transfer_family"

  env                        = var.env
  kms_key_arn                = module.kms.key_arn
  log_group_arn              = module.monitoring.log_group_application_arn
  notification_sns_topic_arn = module.monitoring.sns_topic_arn
  tags                       = local.common_tags
}

# -----------------------------------------------------------------------------
# IAM (depends on: s3, kms, aurora — no circular deps now)
# -----------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  env               = var.env
  aws_account_id    = var.aws_account_id
  aws_region        = var.aws_region
  s3_bucket_arn      = module.s3_documents.bucket_arn
  landing_bucket_arn = module.transfer_family.landing_bucket_arn
  kms_key_arn        = module.kms.key_arn
  master_secret_arn  = module.aurora_postgres.master_secret_arn
  tags               = local.common_tags
}
