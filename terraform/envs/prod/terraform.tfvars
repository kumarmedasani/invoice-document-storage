aws_region     = "us-east-1"
aws_account_id = "123456789012"
env            = "prod"

# Networking
vpc_cidr = "10.30.0.0/16"
az_count = 3

# Aurora
aurora_instance_class        = "db.r8g.large"
aurora_instance_count        = 2
aurora_backup_retention_days = 35
enable_performance_insights  = true
aurora_deletion_protection   = true
enable_rds_proxy             = true
aurora_max_connections       = 4000

# S3
enable_object_lock         = true
object_lock_retention_days = 3650

# Monitoring
alert_email        = "admin@example.com"
log_retention_days = 365

# Tags
cost_center = "IT-1043"

