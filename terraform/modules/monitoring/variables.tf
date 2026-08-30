# =============================================================================
# terraform/modules/monitoring/variables.tf
# =============================================================================

variable "prometheus_stack_version" {
  description = <<-EOF
    kube-prometheus-stack Helm chart version.
    Pin to a specific version for reproducibility.
    Find latest: helm search repo prometheus-community/kube-prometheus-stack
  EOF
  type    = string
  default = "55.5.0"
}

variable "grafana_admin_password" {
  description = <<-EOF
    Grafana admin password.
    Access Grafana at: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
    Then: http://localhost:3000 (user: admin, password: this value)
    Tip: store in .env and reference via var, NOT hardcoded in tfvars.
  EOF
  type      = string
  sensitive = true
  default   = "keda-demo-admin"  # Change before any real/shared deployment
}
