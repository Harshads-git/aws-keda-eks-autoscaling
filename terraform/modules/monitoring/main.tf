# =============================================================================
# terraform/modules/monitoring/main.tf — Prometheus + Grafana Stack
# =============================================================================
# Installs the kube-prometheus-stack Helm chart via Terraform.
# This gives us Prometheus (metrics), Grafana (dashboards), and Alertmanager.
#
# Why kube-prometheus-stack vs standalone Prometheus?
#   kube-prometheus-stack bundles:
#   - Prometheus Operator (manages Prometheus via CRDs)
#   - Prometheus (metrics store)
#   - Grafana (visualization)
#   - Alertmanager (alerting)
#   - kube-state-metrics (K8s object metrics)
#   - node-exporter (node-level CPU/memory/disk metrics)
#   - Pre-built dashboards for Kubernetes
#
# GCP reference repo equivalent:
#   Cloud Monitoring + Cloud Logging (managed, no install needed)
#   This project: self-managed Prometheus on EKS (common in AWS shops)
#
# Cost impact: Prometheus + Grafana pods add ~500MB RAM to nodes.
#   t3.micro (1GB): likely OOM. Recommend t3.small (2GB) for monitoring.
#   OR: use --set grafana.enabled=false to save 200MB during dev.
# =============================================================================

locals {
  monitoring_namespace = "monitoring"
}

# ── Monitoring Namespace ─────────────────────────────────────────────────────
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = local.monitoring_namespace
    labels = {
      name                          = local.monitoring_namespace
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ── kube-prometheus-stack Helm Release ───────────────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.prometheus_stack_version  # e.g., "55.5.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Wait for all pods to be Ready before Terraform considers this done
  wait            = true
  timeout         = 600  # 10 minutes — Prometheus takes time to start
  cleanup_on_fail = true

  # ── Resource Sizing ─────────────────────────────────────────────────────────
  # Tuned for t3.small (2GB RAM). Adjust for larger nodes.
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.cpu"
    value = "500m"
  }

  # ── Prometheus Retention ─────────────────────────────────────────────────────
  # 7 days of metric history (demo project; production usually 30-90 days)
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "7d"
  }

  # ── Grafana Configuration ────────────────────────────────────────────────────
  set {
    name  = "grafana.enabled"
    value = "true"
  }
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  set {
    name  = "grafana.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "grafana.resources.limits.memory"
    value = "256Mi"
  }
  # Grafana service type: ClusterIP (access via kubectl port-forward)
  # Use LoadBalancer for persistent access (adds ALB cost)
  set {
    name  = "grafana.service.type"
    value = "ClusterIP"
  }

  # ── KEDA ServiceMonitor Discovery ─────────────────────────────────────────
  # Allow Prometheus to discover ServiceMonitors in ALL namespaces
  # (KEDA's ServiceMonitor lives in 'keda' namespace)
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  # Accept ServiceMonitors from any namespace (keda, keda-demo, default, etc.)
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorNamespaceSelector"
    value = "{}"
  }

  # ── Alertmanager (minimal for demo) ─────────────────────────────────────
  set {
    name  = "alertmanager.alertmanagerSpec.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.resources.limits.memory"
    value = "128Mi"
  }

  # ── Node Exporter ────────────────────────────────────────────────────────
  # Runs as DaemonSet — one pod per node. Collects CPU, memory, disk metrics.
  set {
    name  = "nodeExporter.resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "nodeExporter.resources.limits.memory"
    value = "64Mi"
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ── Grafana Dashboard: KEDA Scaling Metrics ───────────────────────────────────
# Provision a pre-built KEDA dashboard via ConfigMap (Grafana sidecar picks it up)
resource "kubernetes_config_map" "keda_grafana_dashboard" {
  metadata {
    name      = "keda-scaling-dashboard"
    namespace = local.monitoring_namespace
    labels = {
      # This label tells the Grafana sidecar to load this ConfigMap as a dashboard
      "grafana_dashboard" = "1"
    }
  }

  data = {
    "keda-scaling.json" = jsonencode({
      title       = "KEDA SQS Autoscaling"
      uid         = "keda-sqs-autoscaling"
      description = "KEDA queue depth, replica count, and scaling events"
      tags        = ["keda", "sqs", "autoscaling"]
      panels = [
        {
          title  = "SQS Queue Depth"
          type   = "graph"
          gridPos = { h = 8, w = 12, x = 0, y = 0 }
          targets = [{
            expr         = "keda_scaler_active{namespace=\"keda-demo\"}"
            legendFormat = "Queue Depth"
          }]
        },
        {
          title  = "Consumer Pod Replicas"
          type   = "stat"
          gridPos = { h = 4, w = 6, x = 12, y = 0 }
          targets = [{
            expr         = "kube_deployment_spec_replicas{namespace=\"keda-demo\",deployment=\"keda-demo\"}"
            legendFormat = "Desired Replicas"
          }]
        },
        {
          title  = "Running Consumer Pods"
          type   = "stat"
          gridPos = { h = 4, w = 6, x = 18, y = 0 }
          targets = [{
            expr         = "kube_deployment_status_replicas_ready{namespace=\"keda-demo\",deployment=\"keda-demo\"}"
            legendFormat = "Ready Pods"
          }]
        }
      ]
      schemaVersion = 36
      refresh       = "15s"
    })
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
