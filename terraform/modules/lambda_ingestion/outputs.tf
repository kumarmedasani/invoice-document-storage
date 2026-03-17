output "function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.ingestion.function_name
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.ingestion.arn
}

output "invoke_arn" {
  description = "Lambda invoke ARN (for API Gateway or other triggers)"
  value       = aws_lambda_function.ingestion.invoke_arn
}
