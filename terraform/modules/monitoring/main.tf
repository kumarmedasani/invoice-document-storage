# TODO(registry): extract when team size > 5

locals {
  connection_threshold = floor(var.aurora_max_connections * 0.8)
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
