# TODO(registry): extract when team size > 5

locals {
  cluster_identifier  = "invoice-aurora-${var.env}"
  skip_final_snapshot = var.env == "qa"
}

# -----------------------------------------------------------------------------
# DB Subnet Group
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "invoice-aurora-${var.env}"
  subnet_ids = var.data_subnet_ids

  tags = merge(var.tags, {
    Name = "invoice-aurora-subnet-group-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Cluster Parameter Group
# -----------------------------------------------------------------------------
resource "aws_rds_cluster_parameter_group" "main" {
  name   = "invoice-aurora-params-${var.env}"
  family = "aurora-postgresql16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = merge(var.tags, {
    Name = "invoice-aurora-params-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Enhanced Monitoring IAM Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "enhanced_monitoring" {
  name = "invoice-aurora-monitoring-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  role       = aws_iam_role.enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL Cluster
# -----------------------------------------------------------------------------
resource "aws_rds_cluster" "main" {
  cluster_identifier = local.cluster_identifier
  engine             = "aurora-postgresql"
  engine_version     = "16.2"

  master_username               = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [var.sg_aurora_id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "02:00-03:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = local.skip_final_snapshot
  final_snapshot_identifier = local.skip_final_snapshot ? null : "${local.cluster_identifier}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(var.tags, {
    Name = local.cluster_identifier
  })

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}

# -----------------------------------------------------------------------------
# Aurora Cluster Instances
# -----------------------------------------------------------------------------
resource "aws_rds_cluster_instance" "main" {
  count = var.instance_count

  identifier         = "${local.cluster_identifier}-${count.index}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  performance_insights_enabled    = var.enable_performance_insights
  performance_insights_kms_key_id = var.enable_performance_insights ? var.kms_key_arn : null

  auto_minor_version_upgrade = true
  monitoring_interval        = 60
  monitoring_role_arn        = aws_iam_role.enhanced_monitoring.arn

  tags = merge(var.tags, {
    Name = "${local.cluster_identifier}-${count.index}"
  })
}

# -----------------------------------------------------------------------------
# RDS Proxy (Stage/Prod only)
# -----------------------------------------------------------------------------
resource "aws_db_proxy" "main" {
  count = var.enable_rds_proxy ? 1 : 0

  name                = "invoice-proxy-${var.env}"
  engine_family       = "POSTGRESQL"
  role_arn            = aws_iam_role.rds_proxy[0].arn
  require_tls         = true
  idle_client_timeout = 1800

  vpc_subnet_ids         = var.data_subnet_ids
  vpc_security_group_ids = [var.sg_aurora_id]

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_rds_cluster.main.master_user_secret[0].secret_arn
  }

  tags = merge(var.tags, {
    Name = "invoice-proxy-${var.env}"
  })
}

resource "aws_db_proxy_default_target_group" "main" {
  count = var.enable_rds_proxy ? 1 : 0

  db_proxy_name = aws_db_proxy.main[0].name

  connection_pool_config {
    max_connections_percent = 90
  }
}

resource "aws_db_proxy_target" "main" {
  count = var.enable_rds_proxy ? 1 : 0

  db_proxy_name         = aws_db_proxy.main[0].name
  target_group_name     = aws_db_proxy_default_target_group.main[0].name
  db_cluster_identifier = aws_rds_cluster.main.id
}

# IAM role for RDS Proxy to access Secrets Manager
resource "aws_iam_role" "rds_proxy" {
  count = var.enable_rds_proxy ? 1 : 0

  name = "invoice-rds-proxy-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "rds_proxy" {
  count = var.enable_rds_proxy ? 1 : 0

  name = "invoice-rds-proxy-secrets-${var.env}"
  role = aws_iam_role.rds_proxy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = [aws_rds_cluster.main.master_user_secret[0].secret_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}
