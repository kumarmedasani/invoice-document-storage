# TODO(registry): extract when team size > 5

# -----------------------------------------------------------------------------
# Ingestion Policy (Lambda)
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "ingestion" {
  name        = "invoice-ingestion-policy-${var.env}"
  description = "Policy for invoice document ingestion service - ${var.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
        ]
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        Sid    = "S3ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = var.s3_bucket_arn
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.master_secret_arn
      },
      {
        Sid    = "CloudWatchLogsCreateGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:*"
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/invoice/*"
      }
    ]
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Lambda Ingestion Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ingestion_lambda" {
  name = "invoice-ingestion-lambda-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "invoice-ingestion-lambda-${var.env}"
  })
}

resource "aws_iam_role_policy_attachment" "ingestion_lambda" {
  role       = aws_iam_role.ingestion_lambda.name
  policy_arn = aws_iam_policy.ingestion.arn
}

# -----------------------------------------------------------------------------
# Migration Role (DataSync / ETL runner)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "migration" {
  name = "invoice-migration-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "datasync.amazonaws.com"
        }
      },
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "invoice-migration-${var.env}"
  })
}

resource "aws_iam_role_policy" "migration" {
  name = "invoice-migration-s3-${var.env}"
  role = aws_iam_role.migration.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*"
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}
