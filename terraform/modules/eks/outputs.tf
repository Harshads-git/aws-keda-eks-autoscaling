# =============================================================================
# terraform/modules/eks/outputs.tf
# =============================================================================

output "cluster_name" {
  description = "EKS cluster name. Used in: aws eks update-kubeconfig --name <this>"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint. Used by kubectl and Kubernetes Terraform provider."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the cluster."
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for kubectl TLS verification."
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true  # Contains cluster CA cert — mark sensitive to hide in logs
}

output "cluster_oidc_issuer_url" {
  description = <<-EOF
    EKS OIDC issuer URL. Used to create IRSA IAM roles (Day 13).
    Format: https://oidc.eks.<region>.amazonaws.com/id/<cluster-id>
    The OIDC provider ID (last path segment) is used in IAM trust policies.
  EOF
  value = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC identity provider. Used in IRSA trust policy Condition."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.main.arn
}

output "node_iam_role_arn" {
  description = "ARN of the worker node IAM role. Referenced in aws-auth ConfigMap."
  value       = aws_iam_role.eks_node.arn
}

output "node_security_group_id" {
  description = "Security group ID for worker nodes. Used to allow specific traffic."
  value       = aws_security_group.eks_nodes.id
}

output "kubeconfig_command" {
  description = "Run this command to configure kubectl after terraform apply."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.environment == "dev" ? "us-east-1" : "us-east-1"}"
}
