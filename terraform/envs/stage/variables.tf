variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "env" {
  description = "Environment name"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
}

variable "enable_nat_gateway" {
  description = "Whether to enable NAT Gateway"
  type        = bool
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ"
  type        = bool
  default     = false
}

variable "aurora_instance_class" {
  description = "Aurora instance class"
  type        = string
}

variable "aurora_instance_count" {
  description = "Number of Aurora instances"
  type        = number
}

variable "aurora_backup_retention_days" {
  description = "Aurora backup retention in days"
  type        = number
}

variable "enable_performance_insights" {
  description = "Enable Aurora Performance Insights"
  type        = bool
}

variable "aurora_deletion_protection" {
  description = "Enable Aurora deletion protection"
  type        = bool
}

variable "enable_rds_proxy" {
  description = "Enable RDS Proxy"
  type        = bool
}

variable "enable_object_lock" {
  description = "Enable S3 Object Lock"
  type        = bool
}

variable "object_lock_retention_days" {
  description = "S3 Object Lock retention in days"
  type        = number
  default     = 3650
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
}

variable "aurora_max_connections" {
  description = "Max connections for Aurora instance class (for alarm threshold)"
  type        = number
}

variable "cost_center" {
  description = "Cost center tag value"
  type        = string
}

variable "ingestion_runtime" {
  description = "Primary ingestion runtime (lambda or ecs)"
  type        = string
  default     = "lambda"
}
