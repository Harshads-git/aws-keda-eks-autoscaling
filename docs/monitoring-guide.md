# Monitoring Guide: Prometheus + Grafana for KEDA Autoscaling

This guide explains how to enable, access, and use the monitoring stack
to visualize KEDA autoscaling behaviour in real time.

---

## 1. Architecture Overview

```
Consumer Pods        KEDA Operator
     │                    │
     │                    │ exposes /metrics on :8080
     │                    ▼
     │            keda-operator Service (port: metrics)
     │                    │
     ▼                    ▼
kube-state-metrics  ServiceMonitor (manifests/servicemonitor.yaml)
(pod/deployment         │
 status metrics)        │ Prometheus scrapes every 30s
                        ▼
                   Prometheus
                   (stores time series)
                        │
                        ▼
                   Grafana Dashboards
                   (visualization + alerts)
```

---

## 2. Enabling the Monitoring Stack

Monitoring is **disabled by default** (saves RAM on t3.micro).
Enable it by setting `monitoring_enabled=true` in `terraform.tfvars`:

```hcl
# terraform/terraform.tfvars
monitoring_enabled     = true
node_instance_type     = "t3.small"   # t3.micro too small for monitoring (~500MB RAM)
grafana_admin_password = "your-password-here"
```

Then apply:
```bash
cd terraform
terraform apply -var-file=terraform.tfvars
```

> ⏱️ kube-prometheus-stack takes ~5 minutes to fully start (many CRDs + pods).

---

## 3. Accessing Grafana

```bash
# Port-forward Grafana to localhost:3000
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring

# Or use the terraform output:
terraform output -raw grafana_port_forward_command | bash
```

Open: **http://localhost:3000**
- Username: `admin`
- Password: your `grafana_admin_password` (default: `keda-demo-admin`)

---

## 4. Accessing Prometheus

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
```

Open: **http://localhost:9090**

Test the key PromQL queries:
```promql
# Queue depth KEDA is monitoring
keda_scaler_metrics_value{namespace="keda-demo"}

# Desired pod count (what KEDA computed)
kube_deployment_spec_replicas{deployment="keda-demo",namespace="keda-demo"}

# Running pod count (actual)
kube_deployment_status_replicas_ready{deployment="keda-demo",namespace="keda-demo"}

# KEDA scaler active (1=watching queue, 0=idle)
keda_scaler_active{namespace="keda-demo"}
```

---

## 5. Pre-Built KEDA Dashboard

A "KEDA SQS Autoscaling" dashboard is automatically provisioned via Terraform
(as a Grafana ConfigMap with label `grafana_dashboard: 1`).

**Panels:**
| Panel | Metric | What It Shows |
|---|---|---|
| SQS Queue Depth | `keda_scaler_metrics_value` | Real-time queue depth KEDA sees |
| Desired Replicas | `kube_deployment_spec_replicas` | Pod count KEDA decided on |
| Ready Pods | `kube_deployment_status_replicas_ready` | Pods actually running |

**To observe autoscaling in Grafana:**
1. Open the "KEDA SQS Autoscaling" dashboard
2. Run: `bash scripts/generate-messages.sh --count 25`
3. Watch queue depth spike → Desired Replicas jump to 5 → Ready Pods ramp up
4. After processing: queue empties → 300s cooldown → pods scale to 0

---

## 6. Useful PromQL Queries

### Autoscaling Behaviour
```promql
# Time to scale up (when did pods become Ready after queue spike?)
(kube_deployment_status_replicas_ready{deployment="keda-demo"}) offset 5m

# Scaling lag: difference between desired and ready
kube_deployment_spec_replicas{deployment="keda-demo"} -
  kube_deployment_status_replicas_ready{deployment="keda-demo"}
```

### Resource Usage on Nodes
```promql
# Node memory usage (important on t3.micro/t3.small)
100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100)

# Consumer pod CPU usage
rate(container_cpu_usage_seconds_total{
  namespace="keda-demo",
  container="keda-demo"
}[5m]) * 100
```

### KEDA Health
```promql
# Scaling errors in the last 5 minutes (alert on this)
increase(keda_scaler_error_total[5m])

# Is the ScaledObject paused?
keda_scaled_object_paused{namespace="keda-demo"}
```

---

## 7. Alerting (Alertmanager)

Alertmanager is bundled in kube-prometheus-stack. Example alerts to add:

### Alert: KEDA Scaling Errors
```yaml
# Add to a PrometheusRule resource:
groups:
  - name: keda.rules
    rules:
      - alert: KEDAScalerErrors
        expr: increase(keda_scaler_error_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "KEDA scaling errors detected"
          description: "KEDA scaler errors in namespace {{ $labels.namespace }}"
```

### Alert: SQS DLQ Has Messages
```yaml
      - alert: SQSDLQNotEmpty
        expr: aws_sqs_approximate_number_of_messages_visible{queue_name=~".*-dlq"} > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Messages in Dead Letter Queue"
          description: "Consumer is failing — messages stuck in DLQ"
```

---

## 8. Monitoring Stack Resource Usage

```
Pod                                    CPU req  Memory req  Memory limit
─────────────────────────────────────  ───────  ──────────  ────────────
prometheus-kube-prometheus-stack-0     100m     256Mi       512Mi
grafana-xxxx                           50m      128Mi       256Mi
alertmanager-kube-prometheus-stack-0   10m       64Mi       128Mi
kube-state-metrics-xxxx               10m        64Mi       128Mi
node-exporter-xxxx (DaemonSet)         10m        32Mi        64Mi
─────────────────────────────────────  ───────  ──────────  ────────────
Total (approximate)                   180m     544Mi       ~1.1 GB
```

> ⚠️ This exceeds t3.micro RAM (1GB). Use **t3.small (2GB)** or larger with monitoring enabled.

---

## 9. Verify Monitoring is Working

```bash
# Check all monitoring pods are Running:
kubectl get pods -n monitoring

# Check Prometheus found KEDA targets:
# Go to http://localhost:9090 → Status → Targets
# Look for: keda/keda-operator/0 → UP

# Check ServiceMonitor was picked up:
kubectl get servicemonitor -n keda
# NAME            AGE
# keda-operator   5m
```

If Prometheus target shows DOWN:
```bash
# Check KEDA operator service has the 'metrics' port:
kubectl get svc -n keda keda-operator -o yaml | grep -A5 ports:

# Check Prometheus can reach KEDA:
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  curl http://keda-operator.keda.svc.cluster.local:8080/metrics | head -20
```
