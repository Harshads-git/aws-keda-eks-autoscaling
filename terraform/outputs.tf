# =============================================================================
# terraform/outputs.tf — Root Module Outputs
# =============================================================================
# Outputs expose key values from the Terraform apply:
#   - Other modules can reference these (module.vpc.vpc_id)
#   - CI/CD scripts read these to configure kubectl, deploy manifests
#   - terraform output -json > outputs.json (used by scripts/deploy-all-manifests.sh)
# =============================================================================

# ── Identity ──────────────────────────────────────────────────────────────────

output "aws_account_id" {
  description = "AWS account ID — used in IAM role ARNs and ECR repository URIs."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region all resources were deployed to."
  value       = data.aws_region.current.name
}

# ── VPC ───────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID — passed to EKS module and referenced in security groups."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block — used in security group rules to allow intra-VPC traffic."
  value       = module.vpc.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs — used for ALB placement (must be in 2+ AZs)."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = <<-EOF
    Private subnet IDs — used for EKS node group placement.
    EKS worker nodes run here: no direct internet exposure,
    outbound traffic routes through NAT Gateway.
  EOF
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_ip" {
  description = "Elastic IP of the NAT Gateway — allowlist this IP in downstream firewall rules."
  value       = module.vpc.nat_gateway_ip
}

# ── EKS (populated from Day 10) ───────────────────────────────────────────────

# output "cluster_name" {
#   description = "EKS cluster name — used in aws eks update-kubeconfig command."
#   value       = module.eks.cluster_name
# }

# output "cluster_endpoint" {
#   description = "EKS API server endpoint — used by kubectl and Terraform kubernetes provider."
#   value       = module.eks.cluster_endpoint
# }

# output "cluster_oidc_issuer_url" {
#   description = "EKS OIDC issuer URL — used to create IRSA IAM roles (Day 13)."
#   value       = module.eks.cluster_oidc_issuer_url
# }

# output "kubeconfig_command" {
#   description = "Run this command to configure kubectl after terraform apply."
#   value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
# }
