# =============================================================================
# terraform/modules/monitoring/outputs.tf
# =============================================================================

output "prometheus_namespace" {
  description = "Kubernetes namespace where Prometheus and Grafana are running."
  value       = local.monitoring_namespace
}

output "grafana_service_name" {
  description = "Grafana Kubernetes service name for port-forwarding."
  value       = "kube-prometheus-stack-grafana"
}

output "grafana_port_forward_command" {
  description = "Run this command to access Grafana at http://localhost:3000"
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n ${local.monitoring_namespace}"
}

output "prometheus_port_forward_command" {
  description = "Run this command to access Prometheus UI at http://localhost:9090"
  value       = "kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n ${local.monitoring_namespace}"
}
