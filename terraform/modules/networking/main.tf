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

  # NAT Gateway count: 0 if disabled, 1 if single, az_count if multi
  nat_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0
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
# Internet Gateway (only if NAT Gateway is enabled)
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "invoice-igw-${var.env}"
  })
}

# -----------------------------------------------------------------------------
# Elastic IPs for NAT Gateways
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "invoice-nat-eip-${var.env}-${count.index}"
  })
}

# -----------------------------------------------------------------------------
# Public Subnet for NAT Gateway (NAT needs a public subnet to sit in)
# DECISION: Creating minimal public subnets solely for NAT Gateway placement.
# No other resources are placed here. CIDRs: x.x.100.0/28, x.x.101.0/28, etc.
# -----------------------------------------------------------------------------
resource "aws_subnet" "nat" {
  count = local.nat_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 12, 1600 + count.index)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "invoice-nat-subnet-${var.env}-${local.azs[count.index]}"
    Tier = "nat"
  })
}

resource "aws_route_table" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(var.tags, {
    Name = "invoice-nat-rt-${var.env}"
  })
}

resource "aws_route_table_association" "nat" {
  count = local.nat_count

  subnet_id      = aws_subnet.nat[count.index].id
  route_table_id = aws_route_table.nat[0].id
}

# -----------------------------------------------------------------------------
# NAT Gateways
# -----------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.nat[count.index].id

  tags = merge(var.tags, {
    Name = "invoice-nat-${var.env}-${local.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
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

resource "aws_route" "app_nat" {
  count = var.enable_nat_gateway ? var.az_count : 0

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
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
# Security Group — App (Lambda/ECS)
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
