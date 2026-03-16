output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "app_subnet_ids" {
  description = "List of app subnet IDs"
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "List of data subnet IDs"
  value       = aws_subnet.data[*].id
}

output "sg_app_id" {
  description = "Security group ID for the app tier"
  value       = aws_security_group.app.id
}

output "sg_aurora_id" {
  description = "Security group ID for Aurora"
  value       = aws_security_group.aurora.id
}

output "sg_vpc_endpoints_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}
