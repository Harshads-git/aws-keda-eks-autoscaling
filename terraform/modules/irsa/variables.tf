# =============================================================================
# terraform/modules/irsa/variables.tf
# =============================================================================

variable "project_name" {
  description = "Project name prefix for IAM role names."
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)."
  type        = string
}

variable "oidc_provider_arn" {
  description = <<-EOF
    ARN of the EKS OIDC identity provider.
    Used as Principal.Federated in IAM role trust policies.
    Get from: module.eks.oidc_provider_arn
  EOF
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = <<-EOF
    EKS OIDC issuer URL (without 'https://').
    Used as the key in trust policy Condition.StringEquals map.
    Format: oidc.eks.<region>.amazonaws.com/id/<cluster-id>
    Get from: module.eks.cluster_oidc_issuer_url
  EOF
  type        = string
}

variable "consumer_policy_arn" {
  description = <<-EOF
    ARN of the SQS consumer IAM policy (from module.sqs).
    Attached to the consumer app role.
    Grants: ReceiveMessage, DeleteMessage, ChangeMessageVisibility.
  EOF
  type        = string
}

variable "keda_operator_policy_arn" {
  description = <<-EOF
    ARN of the KEDA operator IAM policy (from module.sqs).
    Attached to the KEDA operator role.
    Grants: GetQueueAttributes only (read-only metric access).
  EOF
  type        = string
}

# ── Kubernetes Identifiers ────────────────────────────────────────────────────
# These must EXACTLY match the K8s ServiceAccount names in your manifests.
# A mismatch here = trust policy condition fails = STS refuses to issue credentials.

variable "app_namespace" {
  description = "K8s namespace where consumer pods run. Must match manifests/namespace.yaml."
  type        = string
  default     = "keda-demo"
}

variable "app_service_account" {
  description = "K8s ServiceAccount name for consumer pods. Must match manifests/serviceaccount.yaml."
  type        = string
  default     = "keda-demo"
}

variable "keda_namespace" {
  description = "K8s namespace where KEDA operator runs. Set by KEDA Helm chart (Day 16)."
  type        = string
  default     = "keda"
}

variable "keda_service_account" {
  description = "K8s ServiceAccount name for KEDA operator. Set by KEDA Helm chart (Day 16)."
  type        = string
  default     = "keda-operator"
}
