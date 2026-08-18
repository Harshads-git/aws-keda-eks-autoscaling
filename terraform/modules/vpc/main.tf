# =============================================================================
# terraform/modules/vpc/main.tf — VPC Module
# =============================================================================
# Creates a production-grade VPC for EKS:
#   - VPC with DNS support (required for EKS)
#   - 2 public subnets (ALB, NAT Gateway) across 2 AZs
#   - 2 private subnets (EKS nodes) across 2 AZs
#   - Internet Gateway (public subnet → internet)
#   - NAT Gateway with Elastic IP (private subnet → internet, outbound only)
#   - Route tables: public (IGW), private (NAT)
#
# EKS subnet tagging (critical):
#   kubernetes.io/role/elb: "1"          → ALB controller creates ALBs here
#   kubernetes.io/role/internal-elb: "1" → Internal ALBs in private subnets
#   kubernetes.io/cluster/<name>: "shared" → EKS discovers subnets
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Required for EKS: DNS hostnames let EKS assign DNS names to EC2 nodes
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
    # EKS uses this tag to discover the VPC associated with the cluster
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
# Enables public subnets to reach the internet
# Also enables internet → public subnet (for ALB inbound traffic)
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# ── Public Subnets ────────────────────────────────────────────────────────────
# One per AZ. Hosts: Application Load Balancers, NAT Gateways
# map_public_ip_on_launch = true: instances here get a public IP automatically
resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Public subnets: instances launched here get a public IP
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${var.availability_zones[count.index]}"

    # ── EKS-required tags ──────────────────────────────────────────────────
    # Tells AWS Load Balancer Controller which subnets to create public ALBs in
    # Without this tag, the ALB controller cannot find subnets → ALB creation fails
    "kubernetes.io/role/elb"                          = "1"
    "kubernetes.io/cluster/${var.cluster_name}"        = "shared"
  }
}

# ── Private Subnets ───────────────────────────────────────────────────────────
# One per AZ. Hosts: EKS worker nodes, RDS databases
# No public IP, no direct internet access → outbound via NAT Gateway
resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Private subnets: no public IPs — EKS nodes are not directly reachable
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${var.availability_zones[count.index]}"

    # ── EKS-required tags ──────────────────────────────────────────────────
    # Tells AWS Load Balancer Controller to create internal ALBs here
    "kubernetes.io/role/internal-elb"                 = "1"
    # Tells EKS to launch worker nodes in these subnets
    "kubernetes.io/cluster/${var.cluster_name}"        = "shared"
  }
}

# ── Elastic IP for NAT Gateway ────────────────────────────────────────────────
# NAT Gateway needs a static public IP (Elastic IP)
# This IP is what external services see as the source IP for your EKS pods
# Count: 1 if single_nat_gateway=true, else 1 per AZ
resource "aws_eip" "nat" {
  count = var.single_nat_gateway ? 1 : length(var.availability_zones)

  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  }

  # EIP must be created after the IGW is attached to the VPC
  depends_on = [aws_internet_gateway.main]
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
# Placed in the FIRST public subnet (or one per AZ in production)
# Allows EKS pods in private subnets to:
#   - Pull Docker images from ECR
#   - Call SQS API
#   - Download OS updates
# WITHOUT being directly accessible from the internet
resource "aws_nat_gateway" "main" {
  count = var.single_nat_gateway ? 1 : length(var.availability_zones)

  allocation_id = aws_eip.nat[count.index].id
  # NAT Gateway MUST be in a PUBLIC subnet (needs IGW for outbound traffic)
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.main]
}

# ── Public Route Table ────────────────────────────────────────────────────────
# Routes: 0.0.0.0/0 → Internet Gateway (all internet traffic goes through IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-public"
  }
}

# Associate public route table with all public subnets
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private Route Tables ──────────────────────────────────────────────────────
# Routes: 0.0.0.0/0 → NAT Gateway (outbound internet via NAT, no inbound)
# If single_nat_gateway=true: all private subnets share one route table
# If single_nat_gateway=false: each AZ's private subnet gets its own route table
#   (so if one AZ's NAT fails, other AZs still work — production best practice)
resource "aws_route_table" "private" {
  count = var.single_nat_gateway ? 1 : length(var.availability_zones)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${local.name_prefix}-rt-private-${count.index + 1}"
  }
}

# Associate private route tables with private subnets
resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}
