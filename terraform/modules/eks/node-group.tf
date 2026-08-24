# =============================================================================
# terraform/modules/eks/node-group.tf — EKS Managed Node Group
# =============================================================================
# Creates the worker nodes (EC2 instances) that run your Kubernetes pods.
# Uses a MANAGED node group — AWS handles node patching and replacement.
# You own: instance type, count, and IAM permissions.
#
# Sizing for this project (Free Tier aware):
#   t3.micro: 2 vCPU, 1 GB RAM, $0.0104/hr
#   Minimum viable for: KEDA operator + consumer pod + system pods
#   WARNING: t3.micro is very tight — expect OOMKilled on heavy workloads.
#   For real testing, consider t3.small (2 vCPU, 2 GB RAM, $0.0208/hr).
#
# GCP equivalent (reference repo):
#   google_container_node_pool "main"
#   machine_type = "e2-medium" (2 vCPU, 4 GB RAM)
# =============================================================================

# ── IAM Role: Worker Nodes ───────────────────────────────────────────────────
# EC2 worker nodes need an IAM role to:
#   - Register with the EKS control plane
#   - Pull container images from ECR
#   - Send logs to CloudWatch (VPC CNI, kubelet)
#   - Manage network interfaces (VPC CNI plugin)
resource "aws_iam_role" "eks_node" {
  name = "${local.cluster_name}-node-role"

  # ec2.amazonaws.com assumes this role (not eks.amazonaws.com like the cluster role)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-node-role"
  }
}

# Three AWS-managed policies required for ALL EKS worker nodes:
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  # Core node permissions: describe EC2, register with EKS API server
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  # VPC CNI plugin: create/delete ENIs, assign private IPs to pods
  # Each pod gets a VPC IP — ENI = Elastic Network Interface
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  # Pull container images from ECR (keda-demo-app image)
  # ReadOnly — nodes can PULL but not PUSH to ECR
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node.name
}

# ── Security Group: Worker Nodes ─────────────────────────────────────────────
# Controls traffic TO/FROM worker nodes.
# The EKS cluster security group handles node↔control-plane traffic.
# This SG handles: node↔node traffic, pod networking, kubelet API.
resource "aws_security_group" "eks_nodes" {
  name        = "${local.cluster_name}-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  # Allow all intra-node-group traffic (pod-to-pod communication)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true  # allow traffic from nodes in the same SG
    description = "Allow all intra-node-group traffic (pod-to-pod)"
  }

  # Allow kubelet API calls from control plane
  # Port 10250: kubelet API (control plane calls this to exec, logs, etc.)
  ingress {
    from_port       = 10250
    to_port         = 10250
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
    description     = "Allow kubelet API from EKS control plane"
  }

  # Allow all outbound (nodes pull images, call SQS, call STS, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${local.cluster_name}-nodes-sg"
    # Required for VPC CNI to identify node security groups
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
  }
}

# ── EKS Managed Node Group ────────────────────────────────────────────────────
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn

  # EKS places nodes in PRIVATE subnets (no direct internet exposure)
  # Outbound internet (ECR pull, SQS API) goes through NAT Gateway
  subnet_ids = var.private_subnet_ids

  # ── Instance Configuration ────────────────────────────────────────────────
  instance_types = [var.node_instance_type]  # default: t3.micro

  # ── Scaling Configuration ─────────────────────────────────────────────────
  # Note: This is EC2 Auto Scaling Group scaling — NOT KEDA pod scaling.
  # KEDA scales PODS (0→5) on fixed nodes.
  # Cluster Autoscaler (Day 20) scales NODES (1→3) based on pod pressure.
  scaling_config {
    desired_size = var.node_desired_size  # default: 1 node
    min_size     = var.node_min_size      # default: 1
    max_size     = var.node_max_size      # default: 3
  }

  # ── Update Policy ─────────────────────────────────────────────────────────
  # During node group update (e.g., k8s version bump):
  # max_unavailable=1: only 1 node drained/replaced at a time
  # Ensures at least (desired - 1) nodes are always running
  update_config {
    max_unavailable = 1
  }

  # ── Node Labels ──────────────────────────────────────────────────────────
  # Applied to all nodes in the group as K8s node labels
  # Used for pod scheduling (nodeSelector, affinity rules)
  labels = {
    "role"                      = "worker"
    "project"                   = var.project_name
    "eks.amazonaws.com/nodegroup" = "${local.cluster_name}-nodes"
  }

  # ── Node Taints ───────────────────────────────────────────────────────────
  # Uncomment to dedicate this node group to specific workloads:
  # taint {
  #   key    = "dedicated"
  #   value  = "keda-demo"
  #   effect = "NO_SCHEDULE"  # only pods that tolerate this taint run here
  # }

  # Ensure IAM policies are attached before creating nodes
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]

  tags = {
    Name = "${local.cluster_name}-nodes"
    # Required for Cluster Autoscaler to discover this node group (Day 20)
    "k8s.io/cluster-autoscaler/enabled"                   = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}"     = "owned"
  }
}
