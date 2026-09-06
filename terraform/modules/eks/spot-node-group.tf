# =============================================================================
# terraform/modules/eks/spot-node-group.tf — Spot Instance Node Group
# =============================================================================
# Adds a SECOND managed node group that uses Spot instances alongside the
# existing On-Demand node group (node-group.tf).
#
# Two-tier node strategy:
#   Tier 1 (node-group.tf):       On-Demand t3.micro  — stable, always available
#     - Runs: KEDA operator, Cluster Autoscaler, critical system pods
#     - Tainted: NoSchedule for regular workloads (not used here — just sized)
#
#   Tier 2 (this file):           Spot mixed fleet   — 60-90% cheaper
#     - Runs: consumer pods (stateless, tolerate interruptions via KEDA reschedule)
#     - Multiple instance types: if one is unavailable, others fill in
#
# Spot interruption handling for KEDA workloads:
#   1. AWS sends 2-minute interruption notice (instance metadata + EC2 event)
#   2. Node gets taint node.kubernetes.io/shutdown:NoSchedule
#   3. aws-node-termination-handler (NTH) cordons node + evicts pods gracefully
#   4. KEDA sees evicted pods → reschedules on remaining Spot or On-Demand nodes
#   5. In-flight SQS message: SIGTERM → app.py finishes message → pod exits
#   6. SQS message is deleted on success. If interrupted mid-delete: visibility
#      timeout expires (30s) → message redelivered → idempotent processing
#
# Cost comparison (us-east-1, Sept 2024):
#   t3.micro  On-Demand: $0.0104/hr  (reference)
#   t3.small  Spot:      $0.0041/hr  (-61% savings)
#   t3.medium Spot:      $0.0073/hr  (-56% savings)
#   m5.large  Spot:      $0.0360/hr  (-56% savings, more CPU/RAM for heavy workloads)
#
# GCP reference repo equivalent:
#   google_container_node_pool with spot = true (GKE Spot nodes)
#   GKE: preemptible=true (older) or spot=true (newer)
#   AWS: capacity_type = "SPOT" + multiple instance types for availability
# =============================================================================

locals {
  spot_instance_types = [
    "t3.small",    # 2 vCPU, 2GB RAM — cheapest Spot, good for light workloads
    "t3.medium",   # 2 vCPU, 4GB RAM — fallback if t3.small unavailable
    "t3a.small",   # AMD variant of t3.small, often cheaper
    "t3a.medium",  # AMD variant of t3.medium
    "m5.large",    # 2 vCPU, 8GB RAM — larger fallback with more RAM headroom
  ]
}

# ── Spot Node Group ───────────────────────────────────────────────────────────
resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-spot"
  node_role_arn   = aws_iam_role.eks_node_group.arn  # Reuse existing node IAM role

  # Use the private subnets (Spot nodes don't need public IPs)
  subnet_ids = var.private_subnet_ids

  # SPOT capacity type — the key setting for Spot pricing
  capacity_type = "SPOT"

  # Multiple instance types → EC2 picks the cheapest available Spot pool
  # More instance types = better availability (less likely to hit "no capacity")
  instance_types = local.spot_instance_types

  scaling_config {
    desired_size = 1   # Start with 1 Spot node
    min_size     = 0   # Can scale to 0 (all pods on On-Demand during low traffic)
    max_size     = 5   # CA can add up to 5 Spot nodes under heavy load
  }

  # CA uses these tags to auto-discover and manage this node group
  # Same tags as On-Demand group (node-group.tf) — CA manages both
  tags = {
    Name        = "${local.cluster_name}-spot-node"
    Environment = var.environment
    NodeGroup   = "spot"
    ManagedBy   = "terraform"

    # Cluster Autoscaler discovery tags (REQUIRED for CA to manage this group)
    "k8s.io/cluster-autoscaler/enabled"                = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}"  = "owned"

    # Spot-specific tag for monitoring and cost allocation
    "eks.amazonaws.com/capacityType" = "SPOT"
  }

  labels = {
    "node-type"                      = "spot"
    "eks.amazonaws.com/capacityType" = "SPOT"
    # Pods use this label in nodeAffinity to target Spot nodes
    "keda-demo/node-class"           = "spot"
  }

  # Taint Spot nodes so only tolerating pods land on them
  # Consumer pods (deployment.yaml) add tolerations for this taint
  taint {
    key    = "spot"
    value  = "true"
    effect = "NO_SCHEDULE"  # No pod without the toleration can schedule here
  }

  update_config {
    max_unavailable = 1  # Rolling update: replace 1 Spot node at a time
  }

  # Wait for IAM role policies to be attached before creating node group
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_readonly,
  ]

  lifecycle {
    # Ignore desired_size changes — CA manages the actual count
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ── Node Termination Handler IAM Role ─────────────────────────────────────────
# aws-node-termination-handler (NTH) watches EC2 Spot interruption notices
# and cordons + drains nodes gracefully before AWS reclaims them.
# NTH needs to describe EC2 instances and put AutoScaling lifecycle actions.
resource "aws_iam_role" "node_termination_handler" {
  name        = "${local.cluster_name}-nth"
  description = "IRSA role for aws-node-termination-handler on Spot nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node-termination-handler"
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name      = "${local.cluster_name}-nth-role"
    Component = "node-termination-handler"
  }
}

resource "aws_iam_role_policy" "node_termination_handler" {
  name = "nth-policy"
  role = aws_iam_role.node_termination_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeTags",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
      ]
      Resource = "*"
    }]
  })
}

output "spot_node_group_name" {
  description = "Spot node group name (for kubectl describe nodegroup)"
  value       = aws_eks_node_group.spot.node_group_name
}

output "nth_role_arn" {
  description = "NTH IRSA role ARN. Use when installing aws-node-termination-handler."
  value       = aws_iam_role.node_termination_handler.arn
}
