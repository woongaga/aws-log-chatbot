data "aws_availability_zones" "az" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "woong-vpc" })
}

locals {
  azs = slice(data.aws_availability_zones.az.names, 0, var.az_count)

  # /16 기준 newbits=4 → /20 서브넷 16개 확보
  public_cidrs      = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_app_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  private_db_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

# IGW
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "woong-igw" })
}

# 퍼블릭 서브넷 (AZ별 1개)
resource "aws_subnet" "public" {
  for_each                = { for idx, az in local.azs : idx => { az = az, cidr = local.public_cidrs[idx] } }
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "public-${each.value.az}" })
}

# NAT: 비용 절감을 위해 1개(첫 AZ)만 생성
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "woong-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id
  tags          = merge(var.tags, { Name = "woong-nat" })
  depends_on    = [aws_internet_gateway.igw]
}

# 프라이빗(앱용) 서브넷 (AZ별 1개, NAT 경유)
resource "aws_subnet" "private_app" {
  for_each          = { for idx, az in local.azs : idx => { az = az, cidr = local.private_app_cidrs[idx] } }
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = merge(var.tags, { Name = "private-app-${each.value.az}" })
}

# 프라이빗(DB용) 서브넷 (AZ별 1개, 외부 경로 없음)
resource "aws_subnet" "private_db" {
  for_each          = { for idx, az in local.azs : idx => { az = az, cidr = local.private_db_cidrs[idx] } }
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = merge(var.tags, { Name = "private-db-${each.value.az}" })
}

# 라우트 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rtb-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private App: NAT 경유
resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rtb-private-app" })
}

resource "aws_route" "private_app_nat" {
  route_table_id         = aws_route_table.private_app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_app" {
  for_each       = aws_subnet.private_app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_app.id
}

# Private DB: 외부 라우트 없음(로컬 only)
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rtb-private-db" })
}

resource "aws_route_table_association" "private_db" {
  for_each       = aws_subnet.private_db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_db.id
}


# VPC Flow Logs → S3 (prefix)
resource "aws_flow_log" "vpc_to_s3" {
  vpc_id                   = aws_vpc.this.id
  log_destination_type     = "s3"
  log_destination          = var.vpc_flow_s3_arn_with_prefix
  traffic_type             = "ALL"
  max_aggregation_interval = 60

  destination_options {
    file_format                = "plain-text"
    per_hour_partition         = true
    hive_compatible_partitions = false
  }

  tags = merge(var.tags, { Name = "vpc-flow-logs" })
}
