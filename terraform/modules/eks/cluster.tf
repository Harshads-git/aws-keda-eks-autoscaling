# =============================================================================
# terraform/modules/eks/cluster.tf — EKS Control Plane + OIDC Provider
# =============================================================================
# Creates the EKS control plane (the Kubernetes API server, etcd, scheduler).
# The control plane is MANAGED by AWS — you never SSH into it.
# You only manage: worker nodes, add-ons, and Kubernetes objects.
#
# GCP equivalent (reference repo):
#   google_container_cluster "main" — the GKE cluster resource
#   google_container_node_pool    — the GKE node pool (separate file: node-group.tf)
#
# AWS equivalent (this file):
#   aws_eks_cluster               — the EKS control plane
#   aws_iam_openid_connect_provider — enables IRSA (Workload Identity equiv.)
#
# Cost note:
#   EKS control plane: $0.10/hour (~$72/month) — always running when cluster exists
#   Worker nodes: separate cost (node-group.tf)
#   Run 'terraform destroy' when not actively testing to minimise costs.
# =============================================================================

locals {
  cluster_name = "${var.project_name}-${var.environment}-cluster"
}

# ── IAM Role: EKS Control Plane ───────────────────────────────────────────────
# The EKS control plane needs an IAM role to call AWS APIs on your behalf:
#   - Create/manage ENIs for pod networking (VPC CNI)
#   - Read EC2 instances (for node registration)
#   - Manage load balancers (for Services of type LoadBalancer)
resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"  # The EKS service assumes this role
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-role"
  }
}

# Attach AWS-managed policy: minimum permissions for EKS control plane
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ── Security Group: Control Plane ─────────────────────────────────────────────
# Controls traffic TO the EKS API server.
# EKS creates a managed security group automatically, but we add a custom one
# for explicit control over which CIDR ranges can reach the API server.
resource "aws_security_group" "eks_cluster" {
  name        = "${local.cluster_name}-sg"
  description = "Security group for EKS control plane API server endpoint"
  vpc_id      = var.vpc_id

  # Egress: allow all outbound (control plane needs to call many AWS APIs)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic from control plane"
  }

  tags = {
    Name = "${local.cluster_name}-sg"
  }
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = concat(var.public_subnet_ids, var.private_subnet_ids)

    security_group_ids = [aws_security_group.eks_cluster.id]

    # endpoint_public_access: kubectl accessible from internet (your laptop)
    # true for dev (you connect from home)
    # false for production (kubectl only via VPN or bastion host)
    endpoint_public_access  = true
    endpoint_private_access = true  # nodes also access API server privately

    # Restrict API server access to your IP (security best practice):
    # public_access_cidrs = ["YOUR_HOME_IP/32"]
    # For now: open to all (acceptable for a demo project)
  }

  # Enable control plane logging to CloudWatch Logs
  # These log groups are created automatically by EKS
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Ensure IAM role permissions are created before the cluster
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = {
    Name = local.cluster_name
  }
}

# ── OIDC Identity Provider ────────────────────────────────────────────────────
# This is the KEY resource that enables IRSA (IAM Roles for Service Accounts).
# It's the AWS equivalent of GKE Workload Identity.
#
# How IRSA works (the OIDC flow):
#   1. EKS generates a unique OIDC issuer URL per cluster (like a JWT authority)
#   2. This resource registers that URL with AWS IAM as a trusted identity provider
#   3. When a pod starts, EKS injects a signed JWT (service account token)
#   4. Pod calls STS: AssumeRoleWithWebIdentity(JWT)
#   5. STS validates JWT against the OIDC provider public keys
#   6. STS returns temporary credentials scoped to the IAM role
#   7. boto3 uses these credentials — no static keys anywhere
#
# GCP Workload Identity equivalent:
#   google_service_account_iam_binding with member "serviceAccount:project.svc.id.goog[ns/sa]"
#   In AWS: IAM role trust policy with Condition on sub = "system:serviceaccount:ns:sa"

# Fetch the OIDC issuer's TLS certificate thumbprint
# Required for IAM to trust the OIDC provider's signed JWTs
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  # The OIDC issuer URL uniquely identifies THIS cluster
  # Format: https://oidc.eks.<region>.amazonaws.com/id/<cluster-id>
  client_id_list  = ["sts.amazonaws.com"]  # STS is the relying party
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name = "${local.cluster_name}-oidc"
  }
}
