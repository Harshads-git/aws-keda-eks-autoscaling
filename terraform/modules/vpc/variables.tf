# =============================================================================
# terraform/modules/vpc/variables.tf — VPC Module Input Variables
# =============================================================================

variable "project_name" {
  description = "Project name prefix for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)."
  type        = string
}

variable "cluster_name" {
  description = <<-EOF
    EKS cluster name. Used in subnet tags:
    kubernetes.io/cluster/<cluster_name> = "shared"
    These tags are required for EKS subnet discovery and ALB controller.
  EOF
  type        = string
  default     = "keda-demo-cluster"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g., 10.0.0.0/16)."
  type        = string
}

variable "availability_zones" {
  description = "List of AZs for subnet placement. Provide exactly 2 for EKS HA."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (ALB, NAT). One per AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (EKS nodes). One per AZ."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway (cheaper) vs one per AZ (HA). Use true for dev."
  type        = bool
  default     = true
}
