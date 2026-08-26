# =============================================================================
# terraform/modules/eks/addons.tf — EKS Managed Add-ons
# =============================================================================
# EKS add-ons are AWS-managed Kubernetes components that run on every cluster.
# Using managed add-ons (vs self-managed): AWS handles versioning and patching.
#
# Required add-ons for this project:
#   vpc-cni      → pod networking (every pod gets a VPC IP)
#   coredns      → DNS resolution inside the cluster (service discovery)
#   kube-proxy   → network rules on each node (iptables for Services)
#   aws-ebs-csi-driver → persistent volumes (needed by KEDA metrics server)
#
# Add-on version strategy:
#   "LATEST" resolves to the latest version compatible with the cluster k8s version.
#   In production, pin to a specific version for predictability:
#     addon_version = "v1.15.1-eksbuild.1"
#
# Conflicts: resolve_conflicts_on_create = "OVERWRITE"
#   If add-on was previously installed manually (e.g., via helm), Terraform
#   will overwrite it with the managed version. Safe for a fresh cluster.
# =============================================================================

# ── Add-on 1: VPC CNI ─────────────────────────────────────────────────────────
# The AWS VPC Container Network Interface plugin.
# Assigns a real VPC IP address to every pod (unlike flannel/calico overlays).
# Required: pods need VPC IPs to call SQS, STS, ECR directly.
# Without this: pods get 172.x overlay IPs and cannot reach AWS services.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # VPC CNI needs IRSA to manage ENIs and assign IPs
  # The AmazonEKS_CNI_Policy is already on the node role (node-group.tf)
  # but for advanced features (IPv6, custom networking) an IRSA role is better.
  # For this demo: node role permissions are sufficient.

  tags = {
    Name = "${local.cluster_name}-addon-vpc-cni"
  }

  depends_on = [aws_eks_node_group.main]
}

# ── Add-on 2: CoreDNS ─────────────────────────────────────────────────────────
# Provides DNS resolution within the cluster.
# Every Kubernetes Service gets a DNS name: <svc>.<namespace>.svc.cluster.local
# Used by: kubectl exec, pod-to-pod communication, service discovery.
# Without this: pods cannot resolve service names (e.g., 'keda-metrics-apiserver')
resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.cluster_name}-addon-coredns"
  }

  # CoreDNS pods must run on worker nodes (not Fargate)
  # Ensure node group is ready before installing
  depends_on = [aws_eks_node_group.main]
}

# ── Add-on 3: kube-proxy ──────────────────────────────────────────────────────
# Maintains network rules on each node for Kubernetes Services.
# Implements: ClusterIP, NodePort, LoadBalancer service routing.
# Uses iptables/ipvs to forward traffic to the correct pod.
# Without this: Services don't work (no iptables rules for routing).
resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.cluster_name}-addon-kube-proxy"
  }

  depends_on = [aws_eks_node_group.main]
}

# ── Add-on 4: EBS CSI Driver ──────────────────────────────────────────────────
# Enables Kubernetes PersistentVolumes backed by Amazon EBS.
# Required by: KEDA metrics server (stores metrics state on a PV).
# Also useful for: databases, stateful workloads needing persistent storage.
#
# Without this: KEDA metrics adapter may fail to store state across restarts.
# PVC lifecycle: create PVC → CSI driver provisions EBS volume → pod mounts it.
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # EBS CSI driver needs permissions to create/attach/detach EBS volumes.
  # The service_account_role_arn provides IRSA credentials for the driver.
  # Note: for simplicity, we use the node role here (day 13+ can add dedicated IRSA)
  # service_account_role_arn = aws_iam_role.ebs_csi.arn  # (production best practice)

  tags = {
    Name = "${local.cluster_name}-addon-ebs-csi"
  }

  depends_on = [aws_eks_node_group.main]
}

# ── Add-on outputs (exposed in outputs.tf) ────────────────────────────────────
# Add-on statuses are surfaced via 'terraform output' for verification.
# Check add-on health: kubectl get pods -n kube-system
