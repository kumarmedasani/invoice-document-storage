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

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateways (false for QA, true for Stage/Prod)"
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ (true for Stage, false for Prod)"
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "AWS region for VPC endpoint service names"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
