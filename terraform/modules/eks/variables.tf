# =============================================================================
# terraform/modules/eks/variables.tf
# =============================================================================

variable "project_name" {
  description = "Project name prefix used in resource names."
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster (e.g., '1.29')."
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be deployed."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs — included in EKS subnet config (for ALB)."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — worker nodes run here (no public IP)."
  type        = list(string)
}

variable "node_instance_type" {
  description = <<-EOF
    EC2 instance type for worker nodes.
    t3.micro (2 vCPU, 1GB): Free Tier eligible, very tight for EKS.
    t3.small (2 vCPU, 2GB): Recommended minimum for stable KEDA + app.
  EOF
  type        = string
  default     = "t3.micro"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of worker nodes (Cluster Autoscaler lower bound)."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes (Cluster Autoscaler upper bound)."
  type        = number
  default     = 3
}
