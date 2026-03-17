variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
}

variable "lambda_role_arn" {
  description = "ARN of the IAM role for the ingestion Lambda"
  type        = string
}

variable "app_subnet_ids" {
  description = "List of app subnet IDs for Lambda VPC configuration"
  type        = list(string)
}

variable "sg_app_id" {
  description = "Security group ID for the app tier (Lambda attachment)"
  type        = string
}

variable "file_notification_sns_topic_arn" {
  description = "ARN of the SNS topic for file drop notifications (triggers Lambda)"
  type        = string
}

variable "landing_bucket_name" {
  description = "Name of the landing zone S3 bucket"
  type        = string
}

variable "documents_bucket_name" {
  description = "Name of the documents S3 bucket"
  type        = string
}

variable "master_secret_arn" {
  description = "ARN of the Aurora master password secret in Secrets Manager"
  type        = string
}

variable "db_endpoint" {
  description = "Database endpoint (RDS Proxy if enabled, else Aurora cluster endpoint)"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name for the ingestion Lambda"
  type        = string
}

variable "memory_size" {
  description = "Lambda memory in MB"
  type        = number
  default     = 512
}

variable "timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 300
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrent executions (-1 for unreserved)"
  type        = number
  default     = -1
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
