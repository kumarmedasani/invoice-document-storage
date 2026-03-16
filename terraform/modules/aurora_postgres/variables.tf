variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for Aurora encryption"
  type        = string
}

variable "data_subnet_ids" {
  description = "List of data subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "sg_aurora_id" {
  description = "Security group ID for Aurora"
  type        = string
}

variable "instance_class" {
  description = "Aurora instance class"
  type        = string
}

variable "instance_count" {
  description = "Number of Aurora instances (1 for QA, 2 for Stage/Prod)"
  type        = number
  default     = 1
}

variable "backup_retention_days" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7
}

variable "enable_performance_insights" {
  description = "Enable Performance Insights (false for QA, true for Stage/Prod)"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection (false for QA, true for Stage/Prod)"
  type        = bool
  default     = false
}

variable "enable_rds_proxy" {
  description = "Enable RDS Proxy (false for QA, true for Stage/Prod)"
  type        = bool
  default     = false
}

variable "master_username" {
  description = "Master username for the Aurora cluster"
  type        = string
  default     = "invoice_admin"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
