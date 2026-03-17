variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for S3 encryption"
  type        = string
}

variable "enable_object_lock" {
  description = "Enable S3 Object Lock (true for Prod only)"
  type        = bool
  default     = false
}

variable "object_lock_retention_days" {
  description = "Object Lock retention period in days (3650 for Prod = 10 years)"
  type        = number
  default     = 3650
}

variable "notification_sns_topic_arn" {
  description = "SNS topic ARN for S3 ObjectCreated events (empty string to disable)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
