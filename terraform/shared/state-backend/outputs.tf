output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB table for state locking"
  value       = aws_dynamodb_table.tfstate_lock.name
}
