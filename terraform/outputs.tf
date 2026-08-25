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

# ── SQS ───────────────────────────────────────────────────────────────────────

output "sqs_queue_url" {
  description = "SQS queue URL. Set as SQS_QUEUE_URL in .env and K8s ConfigMap."
  value       = module.sqs.queue_url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN. Used in IAM policy Resource blocks."
  value       = module.sqs.queue_arn
}

output "sqs_dlq_url" {
  description = "Dead Letter Queue URL. Inspect failed messages here."
  value       = module.sqs.dlq_url
}

output "consumer_policy_arn" {
  description = "IAM policy ARN for consumer pods. Attached to keda-demo-app-role (Day 13)."
  value       = module.sqs.consumer_policy_arn
}

output "keda_operator_policy_arn" {
  description = "IAM policy ARN for KEDA operator. Attached to keda-operator-role (Day 14)."
  value       = module.sqs.keda_operator_policy_arn
}

# ── EKS ───────────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name. Use in: aws eks update-kubeconfig --name <this>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint. Used by kubectl and Kubernetes provider."
  value       = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer_url" {
  description = "EKS OIDC issuer URL. Required for IRSA IAM role trust policies (Day 13)."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "OIDC identity provider ARN. Used in IRSA IAM role trust policy."
  value       = module.eks.oidc_provider_arn
}

output "kubeconfig_command" {
  description = "Run this after terraform apply to configure kubectl."
  value       = module.eks.kubeconfig_command
}

# ── IRSA Role ARNs ────────────────────────────────────────────────────────────

output "consumer_role_arn" {
  description = <<-EOF
    Consumer pod IRSA role ARN.
    Copy this into manifests/serviceaccount.yaml:
      annotations:
        eks.amazonaws.com/role-arn: <this value>
  EOF
  value = module.irsa.consumer_role_arn
}

output "keda_operator_role_arn" {
  description = <<-EOF
    KEDA operator IRSA role ARN.
    Use in KEDA Helm install (Day 16):
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<this value>
  EOF
  value = module.irsa.keda_operator_role_arn
}
