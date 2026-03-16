output "cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.main.id
}

output "cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.main.arn
}

output "writer_endpoint" {
  description = "Writer endpoint (RDS Proxy if enabled, else cluster endpoint)"
  value       = var.enable_rds_proxy ? aws_db_proxy.main[0].endpoint : aws_rds_cluster.main.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint (direct cluster reader, no proxy)"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "master_secret_arn" {
  description = "ARN of the Secrets Manager secret for the master password"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "proxy_endpoint" {
  description = "RDS Proxy endpoint (empty string if proxy is disabled)"
  value       = var.enable_rds_proxy ? aws_db_proxy.main[0].endpoint : ""
}
