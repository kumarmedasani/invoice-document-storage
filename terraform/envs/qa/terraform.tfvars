aws_region     = "us-east-1"
aws_account_id = "123456789012"
env            = "qa"

# Networking
vpc_cidr           = "10.10.0.0/16"
az_count           = 2
enable_nat_gateway = false
single_nat_gateway = false

# Aurora
aurora_instance_class        = "db.t4g.medium"
aurora_instance_count        = 1
aurora_backup_retention_days = 7
enable_performance_insights  = false
aurora_deletion_protection   = false
enable_rds_proxy             = false
aurora_max_connections       = 170

# S3
enable_object_lock         = false
object_lock_retention_days = 3650

# Monitoring
alert_email        = "admin@example.com"
log_retention_days = 90

# Tags
cost_center = "IT-1042"

# Runtime
ingestion_runtime = "lambda"
