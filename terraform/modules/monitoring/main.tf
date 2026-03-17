# TODO(registry): extract when team size > 5

locals {
  connection_threshold = floor(var.aurora_max_connections * 0.8)
  enable_splunk        = var.splunk_hec_endpoint != ""
  log_groups = {
    application = aws_cloudwatch_log_group.application.name
    aurora      = aws_cloudwatch_log_group.aurora.name
    migration   = aws_cloudwatch_log_group.migration.name
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "application" {
  name              = "/invoice/application/${var.env}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "invoice-log-application-${var.env}"
  })
}

resource "aws_cloudwatch_log_group" "aurora" {
  name              = "/invoice/aurora/${var.env}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "invoice-log-aurora-${var.env}"
  })
}

resource "aws_cloudwatch_log_group" "migration" {
  name              = "/invoice/migration/${var.env}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "invoice-log-migration-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# SNS Topic for Alerts
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "invoice-alerts-${var.env}"
  kms_master_key_id = var.kms_key_id

  tags = merge(var.tags, {
    Name = "invoice-alerts-${var.env}"
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "aurora_cpu_high" {
  alarm_name          = "aurora-cpu-high-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Aurora CPU utilization exceeds 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "aurora_storage_high" {
  alarm_name          = "aurora-storage-high-${var.env}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeLocalStorage"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 20000000000 # 20 GB (20% of 100 GB)
  alarm_description   = "Aurora free local storage below 20% of 100GB"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "aurora_connections_high" {
  alarm_name          = "aurora-connections-high-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = local.connection_threshold
  alarm_description   = "Aurora connections exceed 80% of max (${var.aurora_max_connections})"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "aurora_replica_lag_high" {
  alarm_name          = "aurora-replica-lag-high-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 10000
  alarm_description   = "Aurora replica lag exceeds 10,000 ms"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "s3_5xx_errors" {
  alarm_name          = "s3-5xx-errors-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5xxErrors"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "S3 5xx errors exceed 5 in 5 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    BucketName = var.s3_bucket_name
    FilterId   = "AllMetrics"
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "kms_throttles" {
  alarm_name          = "kms-throttles-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottleCount"
  namespace           = "AWS/KMS"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "KMS throttle count exceeds 10 in 5 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    KeyId = var.kms_key_id
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# CloudWatch Dashboard
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "invoice-${var.env}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Aurora CPU Utilization"
          metrics = [["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", var.aurora_cluster_id]]
          period  = 300
          region  = var.aws_region
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Aurora Database Connections"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", var.aurora_cluster_id]]
          period  = 300
          region  = var.aws_region
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Aurora Replica Lag"
          metrics = [["AWS/RDS", "AuroraReplicaLag", "DBClusterIdentifier", var.aurora_cluster_id]]
          period  = 300
          region  = var.aws_region
          stat    = "Maximum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "S3 Request Counts"
          metrics = [
            ["AWS/S3", "AllRequests", "BucketName", var.s3_bucket_name, "FilterId", "AllMetrics"],
            ["AWS/S3", "5xxErrors", "BucketName", var.s3_bucket_name, "FilterId", "AllMetrics"]
          ]
          period = 300
          region = var.aws_region
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "KMS Usage"
          metrics = [
            ["AWS/KMS", "ThrottleCount", "KeyId", var.kms_key_id],
          ]
          period = 300
          region = var.aws_region
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Aurora Free Local Storage"
          metrics = [["AWS/RDS", "FreeLocalStorage", "DBClusterIdentifier", var.aurora_cluster_id]]
          period  = 300
          region  = var.aws_region
          stat    = "Average"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SNS Topic for File Drop Notifications
# External systems subscribe to this topic to trigger customer email on new
# file ingestion. Separate from the alerts topic to avoid mixing concerns.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "file_notifications" {
  name              = "invoice-file-notifications-${var.env}"
  kms_master_key_id = var.kms_key_id

  tags = merge(var.tags, {
    Name = "invoice-file-notifications-${var.env}"
  })
}

resource "aws_sns_topic_policy" "file_notifications" {
  arn = aws_sns_topic.file_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3Publish"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.file_notifications.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::invoice-landing-*"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Kinesis Data Firehose → Splunk
# Streams all CloudWatch Logs to Splunk via HTTP Event Collector (HEC).
# Each environment uses a separate HEC token configured on the Splunk side
# to route logs to the correct index (e.g., invoice_qa, invoice_stage, invoice_prod).
# Disabled when splunk_hec_endpoint is empty.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "firehose_backup" {
  count  = local.enable_splunk ? 1 : 0
  bucket = "invoice-firehose-backup-${var.env}"

  tags = merge(var.tags, {
    Name = "invoice-firehose-backup-${var.env}"
  })
}

resource "aws_s3_bucket_public_access_block" "firehose_backup" {
  count  = local.enable_splunk ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firehose_backup" {
  count  = local.enable_splunk ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "firehose_backup" {
  count  = local.enable_splunk ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    id     = "expire-failed-deliveries"
    status = "Enabled"

    expiration {
      days = 14
    }
  }
}

resource "aws_iam_role" "firehose" {
  count = local.enable_splunk ? 1 : 0
  name  = "invoice-firehose-splunk-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "firehose" {
  count = local.enable_splunk ? 1 : 0
  name  = "invoice-firehose-splunk-${var.env}"
  role  = aws_iam_role.firehose[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BackupWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.firehose_backup[0].arn,
          "${aws_s3_bucket.firehose_backup[0].arn}/*"
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "splunk" {
  count       = local.enable_splunk ? 1 : 0
  name        = "invoice-logs-to-splunk-${var.env}"
  destination = "splunk"

  splunk_configuration {
    hec_endpoint      = var.splunk_hec_endpoint
    hec_token         = var.splunk_hec_token
    hec_endpoint_type = "Event"
    retry_duration    = 300

    s3_configuration {
      role_arn           = aws_iam_role.firehose[0].arn
      bucket_arn         = aws_s3_bucket.firehose_backup[0].arn
      buffering_size     = 5
      buffering_interval = 300
      compression_format = "GZIP"
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.application.name
      log_stream_name = "firehose-splunk-errors"
    }
  }

  tags = merge(var.tags, {
    Name = "invoice-logs-to-splunk-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# CW Logs → Firehose IAM Role
# Allows CloudWatch Logs subscription filters to deliver to Firehose.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cw_to_firehose" {
  count = local.enable_splunk ? 1 : 0
  name  = "invoice-cwlogs-to-firehose-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "logs.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringLike = {
            "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:*"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cw_to_firehose" {
  count = local.enable_splunk ? 1 : 0
  name  = "invoice-cwlogs-to-firehose-${var.env}"
  role  = aws_iam_role.cw_to_firehose[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
        Resource = aws_kinesis_firehose_delivery_stream.splunk[0].arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Logs Subscription Filters → Firehose → Splunk
# One filter per log group. Streams all log events (empty filter_pattern).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_subscription_filter" "splunk" {
  for_each = local.enable_splunk ? local.log_groups : {}

  name            = "splunk-${each.key}-${var.env}"
  log_group_name  = each.value
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.splunk[0].arn
  role_arn        = aws_iam_role.cw_to_firehose[0].arn
}

resource "aws_cloudwatch_log_subscription_filter" "splunk_vpc_flow_logs" {
  count = local.enable_splunk && var.vpc_flow_log_group_name != "" ? 1 : 0

  name            = "splunk-vpc-flow-logs-${var.env}"
  log_group_name  = var.vpc_flow_log_group_name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.splunk[0].arn
  role_arn        = aws_iam_role.cw_to_firehose[0].arn
}
