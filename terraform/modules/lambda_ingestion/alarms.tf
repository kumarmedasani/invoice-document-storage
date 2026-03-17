# -----------------------------------------------------------------------------
# CloudWatch Alarms — Lambda errors, throttles, and DLQ depth
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "lambda-errors-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Ingestion Lambda errors detected"
  alarm_actions       = [var.alert_sns_topic_arn]
  ok_actions          = [var.alert_sns_topic_arn]

  dimensions = {
    FunctionName = aws_lambda_function.ingestion.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "lambda-throttles-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Ingestion Lambda throttled"
  alarm_actions       = [var.alert_sns_topic_arn]
  ok_actions          = [var.alert_sns_topic_arn]

  dimensions = {
    FunctionName = aws_lambda_function.ingestion.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "lambda-dlq-messages-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Ingestion Lambda DLQ has messages — failed processing events"
  alarm_actions       = [var.alert_sns_topic_arn]

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  tags = var.tags
}
