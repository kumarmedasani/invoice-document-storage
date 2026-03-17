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

output "log_group_sftp" {
  description = "CloudWatch log group name for SFTP"
  value       = aws_cloudwatch_log_group.sftp.name
}

output "log_group_sftp_arn" {
  description = "CloudWatch log group ARN for SFTP"
  value       = aws_cloudwatch_log_group.sftp.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "file_notification_sns_topic_arn" {
  description = "ARN of the SNS topic for file drop notifications (external system subscribes for customer email)"
  value       = aws_sns_topic.file_notifications.arn
}

output "firehose_delivery_stream_name" {
  description = "Name of the Kinesis Firehose delivery stream to Splunk (empty if Splunk disabled)"
  value       = local.enable_splunk ? aws_kinesis_firehose_delivery_stream.splunk[0].name : ""
}
