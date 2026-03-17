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

output "dlq_arn" {
  description = "Dead letter queue ARN"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "Dead letter queue URL"
  value       = aws_sqs_queue.dlq.url
}
