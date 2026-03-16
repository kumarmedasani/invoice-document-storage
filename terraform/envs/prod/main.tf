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
# Networking
# -----------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  env                = var.env
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  aws_region         = var.aws_region
  tags               = local.common_tags
}

# -----------------------------------------------------------------------------
# KMS
# -----------------------------------------------------------------------------
module "kms" {
  source = "../../modules/kms"

  env            = var.env
  aws_account_id = var.aws_account_id
  service_principal_arns = [
    module.iam.lambda_role_arn,
    module.iam.ecs_role_arn,
    module.iam.migration_role_arn,
  ]
  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# S3 Documents
# -----------------------------------------------------------------------------
module "s3_documents" {
  source = "../../modules/s3_documents"

  env                        = var.env
  kms_key_arn                = module.kms.key_arn
  ingestion_role_arn         = module.iam.lambda_role_arn
  enable_object_lock         = var.enable_object_lock
  object_lock_retention_days = var.object_lock_retention_days
  notification_sns_topic_arn = module.monitoring.sns_topic_arn
  tags                       = local.common_tags
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL
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
# IAM
# -----------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  env               = var.env
  aws_account_id    = var.aws_account_id
  aws_region        = var.aws_region
  s3_bucket_arn     = module.s3_documents.bucket_arn
  kms_key_arn       = module.kms.key_arn
  master_secret_arn = module.aurora_postgres.master_secret_arn
  ingestion_runtime = var.ingestion_runtime
  tags              = local.common_tags
}

# -----------------------------------------------------------------------------
# Monitoring
# -----------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  env                    = var.env
  aws_account_id         = var.aws_account_id
  aws_region             = var.aws_region
  aurora_cluster_id      = module.aurora_postgres.cluster_id
  s3_bucket_name         = module.s3_documents.bucket_id
  kms_key_id             = module.kms.key_id
  kms_key_arn            = module.kms.key_arn
  alert_email            = var.alert_email
  log_retention_days     = var.log_retention_days
  aurora_max_connections = var.aurora_max_connections
  tags                   = local.common_tags
}
