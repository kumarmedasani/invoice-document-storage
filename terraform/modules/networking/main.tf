# TODO(registry): extract when team size > 5

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # App subnets: x.x.1.0/24, x.x.2.0/24, x.x.3.0/24
  app_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 1)]

  # Data subnets: x.x.11.0/24, x.x.12.0/24, x.x.13.0/24
  data_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 11)]

}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "invoice-vpc-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Private App Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "app" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "invoice-app-subnet-${var.env}-${local.azs[count.index]}"
    Tier = "app"
  })
}

# -----------------------------------------------------------------------------
# Private Data Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "data" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "invoice-data-subnet-${var.env}-${local.azs[count.index]}"
    Tier = "data"
  })
}

# -----------------------------------------------------------------------------
# Route Tables — App Subnets
# -----------------------------------------------------------------------------
resource "aws_route_table" "app" {
  count = var.az_count

  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "invoice-app-rt-${var.env}-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "app" {
  count = var.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# -----------------------------------------------------------------------------
# Route Tables — Data Subnets (local only, no internet egress)
# -----------------------------------------------------------------------------
resource "aws_route_table" "data" {
  count = var.az_count

  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "invoice-data-rt-${var.env}-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "data" {
  count = var.az_count

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data[count.index].id
}

# -----------------------------------------------------------------------------
# S3 Gateway VPC Endpoint
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.app[*].id, aws_route_table.data[*].id)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowInvoiceBucketAccess"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::invoice-docs-*",
          "arn:aws:s3:::invoice-docs-*/*"
        ]
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "invoice-s3-endpoint-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Security Group for VPC Endpoints
# -----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "invoice-vpc-endpoints-${var.env}-"
  description = "Allow HTTPS from app subnets to VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from app subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.app_subnet_cidrs
  }

  tags = merge(var.tags, {
    Name = "invoice-sg-vpc-endpoints-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Interface VPC Endpoints
# -----------------------------------------------------------------------------
locals {
  interface_endpoints = {
    secretsmanager = "com.amazonaws.${var.aws_region}.secretsmanager"
    kms            = "com.amazonaws.${var.aws_region}.kms"
    monitoring     = "com.amazonaws.${var.aws_region}.monitoring"
    logs           = "com.amazonaws.${var.aws_region}.logs"
    sts            = "com.amazonaws.${var.aws_region}.sts"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(var.tags, {
    Name = "invoice-${each.key}-endpoint-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Security Group — App (Lambda)
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name_prefix = "invoice-app-${var.env}-"
  description = "App tier: outbound HTTPS and PostgreSQL"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS to VPC endpoints and internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "PostgreSQL to Aurora"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.aurora.id]
  }

  tags = merge(var.tags, {
    Name = "invoice-sg-app-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Security Group — Aurora
# -----------------------------------------------------------------------------
resource "aws_security_group" "aurora" {
  name_prefix = "invoice-aurora-${var.env}-"
  description = "Aurora: inbound PostgreSQL from app tier only"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "invoice-sg-aurora-${var.env}"
  })
}

resource "aws_security_group_rule" "aurora_ingress" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.aurora.id
  description              = "PostgreSQL from app tier"
}

# -----------------------------------------------------------------------------
# VPC Flow Logs
# -----------------------------------------------------------------------------
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(var.tags, {
    Name = "invoice-vpc-flow-logs-${var.env}"
  })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/invoice-vpc-${var.env}/flow-logs"
  retention_in_days = 90

  tags = merge(var.tags, {
    Name = "invoice-vpc-flow-logs-${var.env}"
  })
}

resource "aws_iam_role" "flow_logs" {
  name = "invoice-vpc-flow-logs-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "invoice-vpc-flow-logs-role-${var.env}"
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "invoice-vpc-flow-logs-${var.env}"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}
