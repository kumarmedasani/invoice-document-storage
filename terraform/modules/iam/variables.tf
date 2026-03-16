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

variable "kms_key_arn" {
  description = "ARN of the KMS key"
  type        = string
}

variable "master_secret_arn" {
  description = "ARN of the Aurora master password secret"
  type        = string
}

variable "ingestion_runtime" {
  description = "Primary ingestion runtime (lambda or ecs) - both roles are created regardless"
  type        = string
  default     = "lambda"
  validation {
    condition     = contains(["lambda", "ecs"], var.ingestion_runtime)
    error_message = "ingestion_runtime must be lambda or ecs"
  }
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
