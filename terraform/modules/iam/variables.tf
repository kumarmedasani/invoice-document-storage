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

variable "s3_bucket_arn" {
  description = "ARN of the S3 documents bucket"
  type        = string
}

variable "landing_bucket_arn" {
  description = "ARN of the S3 landing zone bucket (SFTP uploads)"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key"
  type        = string
}

variable "master_secret_arn" {
  description = "ARN of the Aurora master password secret"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
