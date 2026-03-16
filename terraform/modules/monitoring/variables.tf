variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aurora_cluster_id" {
  description = "Aurora cluster identifier for CloudWatch alarms"
  type        = string
}

variable "s3_bucket_name" {
  description = "S3 documents bucket name for CloudWatch alarms"
  type        = string
}

variable "kms_key_id" {
  description = "KMS key ID for CloudWatch alarms and log encryption"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for log group encryption"
  type        = string
}

variable "alert_email" {
  description = "Email address for SNS alert notifications"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days (90 for QA/Stage, 365 for Prod)"
  type        = number
  default     = 90
}

variable "aurora_max_connections" {
  description = "Max connections for Aurora instance class (used for alarm threshold at 80%)"
  type        = number
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
