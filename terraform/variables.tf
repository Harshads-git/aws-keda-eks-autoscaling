# =============================================================================
# terraform/variables.tf — Input Variables for the Root Module
# =============================================================================
# All configurable values are defined here.
# Actual values are set in terraform.tfvars (gitignored) or passed via -var flag.
# =============================================================================

# ── Project Identity ──────────────────────────────────────────────────────────

variable "project_name" {
  description = "Name prefix for all AWS resources. Used in resource names and tags."
  type        = string
  default     = "keda-demo"

  validation {
    condition     = length(var.project_name) <= 20 && can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, max 20 chars."
  }
}

variable "environment" {
  description = "Deployment environment. Used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources. Must match your EKS cluster region."
  type        = string
  default     = "us-east-1"
}

# ── VPC Networking ────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = <<-EOF
    CIDR block for the VPC.
    /16 gives 65,534 usable IPs — plenty for EKS nodes and pods.
    EKS pods use VPC IPs (AWS VPC CNI), so a large CIDR is important.
  EOF
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = <<-EOF
    CIDR blocks for public subnets (one per AZ).
    Public subnets host: Application Load Balancers, NAT Gateways.
    EKS worker nodes should NOT run here (use private subnets).
    Must provide exactly 2 CIDRs (for 2 AZs).
  EOF
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly 2 public subnet CIDRs required (one per AZ)."
  }
}

variable "private_subnet_cidrs" {
  description = <<-EOF
    CIDR blocks for private subnets (one per AZ).
    Private subnets host: EKS worker nodes, RDS databases.
    No direct internet access — outbound traffic routes through NAT Gateway.
    Must provide exactly 2 CIDRs (for 2 AZs).
  EOF
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly 2 private subnet CIDRs required (one per AZ)."
  }
}

variable "single_nat_gateway" {
  description = <<-EOF
    Use a single NAT Gateway instead of one per AZ.
    true  = cheaper (1 NAT Gateway ~$32/month) — good for dev/demo
    false = HA (1 NAT per AZ, ~$64+/month) — required for production
    For this Free Tier demo: set to true.
  EOF
  type        = bool
  default     = true
}

# ── EKS Cluster (used from Day 10) ───────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the EKS cluster. Used in kubeconfig and IAM trust policies."
  type        = string
  default     = "keda-demo-cluster"
}

variable "cluster_version" {
  description = <<-EOF
    Kubernetes version for the EKS cluster.
    AWS supports the last 3 minor versions. Check:
    https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
  EOF
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = <<-EOF
    EC2 instance type for EKS worker nodes.
    t3.micro: 2 vCPU, 1GB RAM — AWS Free Tier eligible (750 hrs/month)
    t3.small: 2 vCPU, 2GB RAM — recommended minimum for KEDA + app pods
    Note: EKS control plane ($0.10/hr) is NOT Free Tier.
  EOF
  type        = string
  default     = "t3.micro"
}

variable "node_desired_size" {
  description = "Desired number of EKS worker nodes in the node group."
  type        = number
  default     = 1

  validation {
    condition     = var.node_desired_size >= 1 && var.node_desired_size <= 10
    error_message = "node_desired_size must be between 1 and 10."
  }
}

variable "node_min_size" {
  description = "Minimum number of EKS worker nodes (for cluster autoscaler)."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of EKS worker nodes (for cluster autoscaler)."
  type        = number
  default     = 3
}

# ── Application ───────────────────────────────────────────────────────────────

variable "sqs_queue_name" {
  description = "Name of the SQS queue that KEDA monitors for autoscaling."
  type        = string
  default     = "keda-demo-queue"
}

variable "app_namespace" {
  description = "Kubernetes namespace where the KEDA demo application runs."
  type        = string
  default     = "keda-demo"
}
