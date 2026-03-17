output "lambda_role_arn" {
  description = "ARN of the Lambda ingestion IAM role"
  value       = aws_iam_role.ingestion_lambda.arn
}

output "migration_role_arn" {
  description = "ARN of the migration IAM role"
  value       = aws_iam_role.migration.arn
}

output "ingestion_policy_arn" {
  description = "ARN of the shared ingestion IAM policy"
  value       = aws_iam_policy.ingestion.arn
}
