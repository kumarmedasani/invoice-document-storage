# TODO(registry): extract when team size > 5

locals {
  landing_bucket_name = "invoice-landing-${var.env}"
}

# -----------------------------------------------------------------------------
# Landing Zone S3 Bucket
# Transient staging area for vendor SFTP uploads. Files are processed by
# Lambda (ZIP extraction) then deleted. 7-day lifecycle as safety net.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "landing" {
  bucket = local.landing_bucket_name

  tags = merge(var.tags, {
    Name = local.landing_bucket_name
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "landing" {
  bucket = aws_s3_bucket.landing.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "landing" {
  bucket = aws_s3_bucket.landing.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "landing" {
  bucket = aws_s3_bucket.landing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.landing.arn,
          "${aws_s3_bucket.landing.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_versioning" "landing" {
  bucket = aws_s3_bucket.landing.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "landing" {
  bucket = aws_s3_bucket.landing.id

  rule {
    id     = "expire-after-processing"
    status = "Enabled"

    expiration {
      days = 7
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# -----------------------------------------------------------------------------
# S3 Event Notification — Landing bucket → SNS → Lambda
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_notification" "landing" {
  count = var.notification_sns_topic_arn != "" ? 1 : 0

  bucket = aws_s3_bucket.landing.id

  topic {
    topic_arn = var.notification_sns_topic_arn
    events    = ["s3:ObjectCreated:*"]
  }
}

# -----------------------------------------------------------------------------
# AWS Transfer Family SFTP Server
# Vendors drop invoice files via SFTP → lands in landing bucket
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
# Scoped to landing zone bucket only — no access to documents bucket
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

# -----------------------------------------------------------------------------
# SFTP Users (created from var.sftp_users map)
# Each user gets a home directory scoped to the landing bucket.
# -----------------------------------------------------------------------------
resource "aws_transfer_user" "vendor" {
  for_each = var.sftp_users

  server_id = aws_transfer_server.sftp.id
  user_name = each.key
  role      = aws_iam_role.sftp_user.arn

  home_directory_type = "LOGICAL"

  home_directory_mappings {
    entry  = "/"
    target = "/${aws_s3_bucket.landing.id}"
  }

  tags = merge(var.tags, {
    Name = "invoice-sftp-user-${each.key}-${var.env}"
  })
}

resource "aws_transfer_ssh_key" "vendor" {
  for_each = var.sftp_users

  server_id = aws_transfer_server.sftp.id
  user_name = aws_transfer_user.vendor[each.key].user_name
  body      = each.value
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
        Resource = aws_s3_bucket.landing.arn
      },
      {
        Sid    = "S3ReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = "${aws_s3_bucket.landing.arn}/*"
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
