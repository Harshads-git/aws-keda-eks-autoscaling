# =============================================================================
# terraform/modules/vpc/outputs.tf — VPC Module Outputs
# =============================================================================
# Exposes VPC resource IDs for consumption by other modules (EKS, IRSA, SQS).
# Root module accesses these as: module.vpc.vpc_id, module.vpc.private_subnet_ids
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC. Passed to EKS module and security group rules."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC. Used in security group ingress rules."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of public subnets. Used for ALB placement (needs 2+ AZs)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets. Used for EKS node group placement."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ip" {
  description = "Public IP(s) of NAT Gateway(s). Allowlist in downstream firewalls."
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of private route tables (1 if single_nat_gateway, else 1 per AZ)."
  value       = aws_route_table.private[*].id
}
