# TODO(registry): extract when team size > 5

# S3 KEY PREFIX CONVENTION:
# {source_system}/{year}/{month}/{account_id}/{document_uuid}.pdf
# Example: billing_system/2024/03/ACC-00123456/d4e5f6a7-b8c9-1234-5678-abcdef012345.pdf

locals {
  bucket_name = "invoice-docs-${var.env}"
}

resource "aws_s3_bucket" "documents" {
  bucket              = local.bucket_name
  object_lock_enabled = var.enable_object_lock

  tags = merge(var.tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "documents" {
  bucket = aws_s3_bucket.documents.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.documents.arn,
          "${aws_s3_bucket.documents.arn}/*"
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

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "document-lifecycle"
    status = "Enabled"

    transition {
      days          = 731
      storage_class = "GLACIER"
    }

    transition {
      days          = 2556
      storage_class = "DEEP_ARCHIVE"
    }

    # DECISION: expiration at day 3650 is safe because Object Lock retention
    # also ends at day 3650 in GOVERNANCE mode (Prod only).
    expiration {
      days = 3650
    }
  }

  rule {
    id     = "noncurrent-version-lifecycle"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.documents]
}

resource "aws_s3_bucket_object_lock_configuration" "documents" {
  count = var.enable_object_lock ? 1 : 0

  bucket = aws_s3_bucket.documents.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_retention_days
    }
  }
}

# -----------------------------------------------------------------------------
# S3 Access Logging Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "access_logs" {
  bucket = "${local.bucket_name}-access-logs"

  tags = merge(var.tags, {
    Name = "${local.bucket_name}-access-logs"
  })
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_logging" "documents" {
  bucket = aws_s3_bucket.documents.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access-logs/"
}

# -----------------------------------------------------------------------------
# S3 Event Notification
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_notification" "documents" {
  count = var.notification_sns_topic_arn != "" ? 1 : 0

  bucket = aws_s3_bucket.documents.id

  topic {
    topic_arn = var.notification_sns_topic_arn
    events    = ["s3:ObjectCreated:*"]
  }
}
