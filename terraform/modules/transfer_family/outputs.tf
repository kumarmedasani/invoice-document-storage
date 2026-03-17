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
