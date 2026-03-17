# -----------------------------------------------------------------------------
# SNS Trigger — subscribe Lambda to file drop notifications
# -----------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "lambda_trigger" {
  topic_arn = var.file_notification_sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.ingestion.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.file_notification_sns_topic_arn
}
