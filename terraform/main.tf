# =============================================================================
# terraform/main.tf — Root Terraform Module
# =============================================================================
# This is the entry point for all infrastructure provisioning.
# It composes individual modules (vpc, eks, irsa, sqs) into a complete stack.
#
# Architecture:
#   VPC Module     → networking foundation (subnets, NAT, IGW)
#   SQS Module     → message queue (Day 9)
#   EKS Module     → Kubernetes cluster (Days 10-12)
#   IRSA Module    → IAM roles for pods (Days 13-14)
#
# State storage: S3 backend (configured in backend.tf — Day 9)
# Secrets: No secrets in Terraform — IAM roles handle all auth via IRSA
#
# Apply:
#   terraform init
#   terraform plan  -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
#
# Destroy (careful — this removes ALL infrastructure):
#   terraform destroy -var-file=terraform.tfvars
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    # TLS provider: fetches OIDC certificate thumbprint for IRSA setup
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # ── S3 Backend (uncomment on Day 9 after running scripts/setup-terraform-state.sh)
  # Stores terraform.tfstate in S3 instead of locally.
  # This enables team collaboration and prevents state loss.
  # Local state is fine for solo development until Day 9.
  #
  # backend "s3" {
  #   bucket         = "keda-demo-tfstate-<YOUR_ACCOUNT_ID>"
  #   key            = "aws-keda-eks-autoscaling/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "keda-demo-tfstate-lock"  # prevents concurrent applies
  # }
}

# ── AWS Provider ─────────────────────────────────────────────────────────────
# Credentials: DO NOT set access_key / secret_key here.
# Use: aws configure (sets ~/.aws/credentials)
# Or:  AWS_PROFILE environment variable
# CI:  GitHub Actions OIDC (Day 22) — no static keys stored in GitHub
provider "aws" {
  region = var.aws_region

  # Default tags applied to ALL AWS resources created by Terraform
  # This ensures every resource is traceable to this project in AWS Cost Explorer
  default_tags {
    tags = {
      Project     = "keda-autoscaling-demo"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "Harshads-git/aws-keda-eks-autoscaling"
    }
  }
}

# ── Data Sources ──────────────────────────────────────────────────────────────
# Fetch current AWS account ID and region dynamically
# Avoids hardcoding account IDs in resource definitions
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Available AZs in the configured region
# Used by the VPC module to spread subnets across AZs for HA
data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC Module ────────────────────────────────────────────────────────────────
# Creates the networking foundation:
#   - VPC with DNS resolution enabled
#   - 2 public subnets (ALB, NAT Gateway)
#   - 2 private subnets (EKS worker nodes — isolated from internet)
#   - Internet Gateway (public subnet internet access)
#   - NAT Gateway (private subnet outbound-only internet access)
#   - Route tables (public → IGW, private → NAT)
module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr

  # Use first 2 available AZs for subnets
  # EKS requires nodes in at least 2 AZs for the control plane to be HA
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # Single NAT Gateway (reduces cost for demo — production uses 1 per AZ)
  single_nat_gateway = true
}

# ── SQS Module ────────────────────────────────────────────────────────────────
# Creates the SQS queue that KEDA monitors and consumer pods process.
# Replaces the manual scripts/setup-sqs.sh for infrastructure lifecycle.
# Also creates IAM policies for consumer pods and KEDA operator (used Day 13-14).
module "sqs" {
  source = "./modules/sqs"

  project_name = var.project_name
  environment  = var.environment
  queue_name   = var.sqs_queue_name

  # Visibility timeout must be >= app.py processing time
  # app.py processes in ~0.1s; 30s gives ample safety margin
  visibility_timeout = 30

  # Long polling (20s) — reduces SQS API calls by ~20x vs short polling
  receive_wait_time = 20

  # maxReceiveCount=3: 3 delivery attempts before message goes to DLQ
  # Protects against poison pill messages blocking the queue
  max_receive_count = 3
}

# ── EKS Module ────────────────────────────────────────────────────────────────
# Creates the Kubernetes control plane, worker nodes, and OIDC provider.
# This is the resource that makes 'kubectl apply' work against a real cluster.
# Cost: $0.10/hr (control plane) + $0.0104/hr (t3.micro node) = ~$79.50/month
# Destroy when not actively testing: terraform destroy
module "eks" {
  source = "./modules/eks"

  project_name = var.project_name
  environment  = var.environment

  # Networking: pass VPC outputs into EKS module
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  # Cluster config
  cluster_version = var.cluster_version

  # Node group sizing
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
}

# ── Locals: Convenience Values ───────────────────────────────────────────────
locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Common name prefix for all resources
  name_prefix = "${var.project_name}-${var.environment}"

  # SQS values used in K8s ConfigMap and KEDA ScaledObject
  sqs_queue_url = module.sqs.queue_url
}
