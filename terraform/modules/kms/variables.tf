variable "env" {
  description = "Environment name (qa, stage, prod)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for key policy"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
