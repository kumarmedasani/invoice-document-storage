output "sftp_server_id" {
  description = "Transfer Family SFTP server ID"
  value       = aws_transfer_server.sftp.id
}

output "sftp_server_endpoint" {
  description = "Transfer Family SFTP server endpoint"
  value       = aws_transfer_server.sftp.endpoint
}

output "sftp_user_role_arn" {
  description = "IAM role ARN for SFTP vendor users"
  value       = aws_iam_role.sftp_user.arn
}

output "landing_bucket_arn" {
  description = "ARN of the landing zone S3 bucket"
  value       = aws_s3_bucket.landing.arn
}

output "landing_bucket_name" {
  description = "Name of the landing zone S3 bucket"
  value       = aws_s3_bucket.landing.id
}
