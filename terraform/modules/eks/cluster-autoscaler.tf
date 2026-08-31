# =============================================================================
# terraform/modules/eks/cluster-autoscaler.tf — Cluster Autoscaler IRSA Role
# =============================================================================
# The Cluster Autoscaler (CA) adjusts the NUMBER OF NODES based on pod pressure.
# KEDA adjusts the NUMBER OF PODS based on queue depth.
# They are COMPLEMENTARY, not competing.
#
# Two-level scaling architecture:
#
#   Level 1 (KEDA):           SQS queue depth → Pod count
#     Queue empty             → 0 pods (scale to zero)
#     25 messages, target=5   → 5 pods (across existing nodes)
#
#   Level 2 (Cluster Autoscaler): Pod pressure → Node count
#     All nodes have capacity  → keep 1 node
#     Pods Pending (no room)   → add node (up to node_max_size=3)
#     Nodes idle too long      → remove node (back to node_min_size=1)
#
# For this demo (t3.micro, 1 node):
#   KEDA might schedule 5 pods → all 5 fit on 1 t3.micro (just barely)
#   CA won't add nodes unless Pending pods exist
#   If you increase traffic (50+ messages), CA adds a 2nd node
#
# GCP reference repo equivalent:
#   google_container_node_pool → autoscaling block with min/max
#   GKE manages cluster autoscaler automatically (no separate install)
#   In AWS: you must install CA yourself (hence this file)
#
# This file creates the IAM role for CA. The CA Helm chart installation
# is done in scripts/install-cluster-autoscaler.sh.
# =============================================================================

# ── IAM Role: Cluster Autoscaler ─────────────────────────────────────────────
# Cluster Autoscaler needs IAM permissions to:
#   - Read Auto Scaling group state (to know current desired capacity)
#   - Set desired capacity (to add/remove nodes)
#   - Describe EC2 instances (to track which nodes exist)
resource "aws_iam_role" "cluster_autoscaler" {
  name        = "${local.cluster_name}-cluster-autoscaler"
  description = "IRSA role for Cluster Autoscaler — EC2 Auto Scaling permissions"

  # Trust policy: only the cluster-autoscaler ServiceAccount can assume this role
  # The SA runs in 'kube-system' namespace (standard CA deployment)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ClusterAutoscalerIRSA"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name      = "${local.cluster_name}-cluster-autoscaler-role"
    Component = "cluster-autoscaler"
  }
}

# ── IAM Policy: Cluster Autoscaler Permissions ────────────────────────────────
resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ClusterAutoscalerAll"
        Effect = "Allow"
        Action = [
          # Read Auto Scaling group details
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          # Read instance types (for capacity decisions)
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          # Read tags (CA uses k8s.io/cluster-autoscaler tags to find node groups)
          "autoscaling:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "ClusterAutoscalerOwn"
        Effect = "Allow"
        Action = [
          # Modify Auto Scaling group capacity (the key permission)
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          # Only modify ASGs that belong to this specific EKS cluster
          # CA discovers node groups via these tags (set in node-group.tf)
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"               = "true"
          }
        }
      }
    ]
  })
}

# ── Output: CA Role ARN ────────────────────────────────────────────────────────
# Exposed so install-cluster-autoscaler.sh can annotate the SA correctly
output "cluster_autoscaler_role_arn" {
  description = <<-EOF
    IRSA role ARN for Cluster Autoscaler.
    Use in: scripts/install-cluster-autoscaler.sh
    Or: helm install cluster-autoscaler ... --set rbac.serviceAccount.annotations.eks.amazonaws.com/role-arn=<this>
  EOF
  value = aws_iam_role.cluster_autoscaler.arn
}
