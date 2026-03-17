# -----------------------------------------------------------------------------
# Dead Letter Queue — captures failed invocations for investigation
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                       = "invoice-ingestion-dlq-${var.env}"
  message_retention_seconds  = 1209600 # 14 days
  kms_master_key_id          = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.tags, {
    Name = "invoice-ingestion-dlq-${var.env}"
  })
}

# Lambda needs permission to send messages to the DLQ
resource "aws_iam_role_policy" "dlq_send" {
  name = "invoice-ingestion-dlq-${var.env}"
  role = split("/", var.lambda_role_arn)[1]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      }
    ]
  })
}
