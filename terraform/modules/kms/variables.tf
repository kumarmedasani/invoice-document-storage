variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for key policy"
  type        = string
}

variable "service_principal_arns" {
  description = "List of IAM role ARNs allowed to use the KMS key"
  type        = list(string)
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
