variable "aws_account_id" {
  description = "AWS account ID used in the state bucket name"
  type        = string
}

variable "aws_region" {
  description = "AWS region for the state backend resources"
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Common tags for state backend resources"
  type        = map(string)
  default = {
    Project   = "invoice-doc-storage"
    ManagedBy = "terraform"
  }
}
