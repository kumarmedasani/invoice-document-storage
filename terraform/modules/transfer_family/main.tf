# TODO(registry): extract when team size > 5

# -----------------------------------------------------------------------------
# AWS Transfer Family SFTP Server
# Vendors drop invoice files via SFTP → lands in S3 → triggers ingestion
# -----------------------------------------------------------------------------
resource "aws_transfer_server" "sftp" {
  identity_provider_type = "SERVICE_MANAGED"
  endpoint_type          = "PUBLIC"
  protocols              = ["SFTP"]

  logging_role = aws_iam_role.transfer_logging.arn

  tags = merge(var.tags, {
    Name = "invoice-sftp-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Transfer Family Logging Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "transfer_logging" {
  name = "invoice-sftp-logging-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "transfer.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "transfer_logging" {
  name = "invoice-sftp-logging-${var.env}"
  role = aws_iam_role.transfer_logging.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${var.log_group_arn}:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SFTP User Access Role (shared by all vendor users)
# Scoped to vendor-uploads/ prefix in the documents bucket
# -----------------------------------------------------------------------------
resource "aws_iam_role" "sftp_user" {
  name = "invoice-sftp-user-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "transfer.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "sftp_user" {
  name = "invoice-sftp-user-s3-${var.env}"
  role = aws_iam_role.sftp_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = var.s3_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = "vendor-uploads/*"
          }
        }
      },
      {
        Sid    = "S3PutObject"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = "${var.s3_bucket_arn}/vendor-uploads/*"
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
