output "bucket_id" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.documents.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.documents.arn
}

output "bucket_regional_domain_name" {
  description = "S3 bucket regional domain name"
  value       = aws_s3_bucket.documents.bucket_regional_domain_name
}
