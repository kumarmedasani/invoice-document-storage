output "sns_topic_arn" {
  description = "ARN of the SNS alerts topic"
  value       = aws_sns_topic.alerts.arn
}

output "log_group_application" {
  description = "CloudWatch log group name for the application"
  value       = aws_cloudwatch_log_group.application.name
}

output "log_group_application_arn" {
  description = "CloudWatch log group ARN for the application"
  value       = aws_cloudwatch_log_group.application.arn
}

output "log_group_aurora" {
  description = "CloudWatch log group name for Aurora"
  value       = aws_cloudwatch_log_group.aurora.name
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
