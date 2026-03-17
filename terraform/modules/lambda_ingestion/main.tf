# -----------------------------------------------------------------------------
# Lambda Function — Invoice Document Ingestion
# Triggered by SNS (file drop notifications from S3 landing bucket).
# Runs inside the VPC (app subnets) to access Aurora via RDS Proxy and
# AWS services via VPC endpoints.
# -----------------------------------------------------------------------------

# Allow Lambda to attach ENIs in the VPC (required for VPC-attached Lambdas).
# This is an AWS-managed policy, not a custom one.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = split("/", var.lambda_role_arn)[1]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# -----------------------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "ingestion" {
  function_name = "invoice-ingestion-${var.env}"
  description   = "Processes vendor file uploads from the landing zone bucket"

  # Placeholder — deploy pipeline will update this to a real S3 key or image URI.
  # Using a stub zip so Terraform can create the resource.
  filename         = data.archive_file.stub.output_path
  source_code_hash = data.archive_file.stub.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"

  role    = var.lambda_role_arn
  timeout = var.timeout

  memory_size                    = var.memory_size
  reserved_concurrent_executions = var.reserved_concurrent_executions

  vpc_config {
    subnet_ids         = var.app_subnet_ids
    security_group_ids = [var.sg_app_id]
  }

  environment {
    variables = {
      ENV                   = var.env
      LANDING_BUCKET        = var.landing_bucket_name
      DOCUMENTS_BUCKET      = var.documents_bucket_name
      DB_SECRET_ARN         = var.master_secret_arn
      DB_ENDPOINT           = var.db_endpoint
      LOG_LEVEL             = var.env == "prod" ? "INFO" : "DEBUG"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = var.log_group_name
  }

  tags = merge(var.tags, {
    Name = "invoice-ingestion-${var.env}"
  })
}

# Stub deployment package — replaced by CI/CD pipeline with real code.
data "archive_file" "stub" {
  type        = "zip"
  output_path = "${path.module}/stub.zip"

  source {
    content  = <<-PYTHON
      import json

      def handler(event, context):
          """Stub handler — replace with real ingestion code via CI/CD."""
          print(json.dumps({"message": "stub handler invoked", "event": event}))
          return {"statusCode": 200}
    PYTHON
    filename = "index.py"
  }
}

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
