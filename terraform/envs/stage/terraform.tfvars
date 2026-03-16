aws_region     = "us-east-1"
aws_account_id = "123456789012"
env            = "stage"

# Networking
vpc_cidr           = "10.20.0.0/16"
az_count           = 2
enable_nat_gateway = true
single_nat_gateway = true

# Aurora
aurora_instance_class        = "db.t4g.large"
aurora_instance_count        = 2
aurora_backup_retention_days = 14
enable_performance_insights  = true
aurora_deletion_protection   = true
enable_rds_proxy             = true
aurora_max_connections       = 340

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
