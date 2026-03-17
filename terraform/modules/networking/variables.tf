variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
  validation {
    condition     = contains(["qa", "stage", "prod"], var.env)
    error_message = "env must be one of: qa, stage, prod"
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "az_count" {
  description = "Number of availability zones (2 for QA/Stage, 3 for Prod)"
  type        = number
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3"
  }
}

variable "aws_region" {
  description = "AWS region for VPC endpoint service names"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encrypting VPC Flow Logs log group"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
