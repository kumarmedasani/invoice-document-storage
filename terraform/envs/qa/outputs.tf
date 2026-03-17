output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "s3_bucket_name" {
  description = "S3 documents bucket name"
  value       = module.s3_documents.bucket_id
}

output "s3_bucket_arn" {
  description = "S3 documents bucket ARN"
  value       = module.s3_documents.bucket_arn
}

output "aurora_writer_endpoint" {
  description = "Aurora writer endpoint"
  value       = module.aurora_postgres.writer_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint"
  value       = module.aurora_postgres.reader_endpoint
}

output "aurora_master_secret_arn" {
  description = "Aurora master password secret ARN"
  value       = module.aurora_postgres.master_secret_arn
}

output "kms_key_arn" {
  description = "KMS key ARN"
  value       = module.kms.key_arn
}

output "sns_topic_arn" {
  description = "SNS alerts topic ARN"
  value       = module.monitoring.sns_topic_arn
}

output "lambda_role_arn" {
  description = "Lambda ingestion role ARN"
  value       = module.iam.lambda_role_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = module.monitoring.dashboard_name
}

output "sftp_server_endpoint" {
  description = "Transfer Family SFTP server endpoint"
  value       = module.transfer_family.sftp_server_endpoint
}

output "landing_bucket_name" {
  description = "Landing zone S3 bucket name"
  value       = module.transfer_family.landing_bucket_name
}
