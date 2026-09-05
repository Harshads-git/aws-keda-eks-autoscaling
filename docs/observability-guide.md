# Observability Guide: Custom Metrics + Alerting

This guide explains the full observability stack added in Day 20:
custom application Prometheus metrics, alert rules, and how all layers
combine into a complete autoscaling observability picture.

---

## 1. Metric Layers in This Project

```
┌──────────────────────────────────────────────────────────────┐
│                     Grafana Dashboard                         │
└────────┬────────────────┬────────────────┬────────────────────┘
         │                │                │
         ▼                ▼                ▼
  App Metrics       KEDA Metrics    kube-state-metrics
  (Day 20)          (Day 16)        (bundled with stack)
  /metrics:8080     :8080/metrics   :8080/metrics
         │                │                │
         └────────────────┴────────────────┘
                          │
                     Prometheus
                     (collects + stores)
                          │
                    Alertmanager
                    (routes alerts → Slack/email)
```

| Source | Metrics | What you learn |
|---|---|---|
| **App (prometheus_client)** | messages_processed, failures, duration | Business throughput |
| **KEDA operator** | scaler_metrics_value, scaler_errors | Scaling decisions |
| **kube-state-metrics** | deployment replicas, pod status | K8s resource state |
| **node-exporter** | CPU, memory, disk per node | Infrastructure health |

---

## 2. Application Metrics (Custom)

Added to [`application/app.py`](../application/app.py) using `prometheus_client`.

### Available Metrics

```promql
# Total messages successfully processed (Counter — only goes up)
keda_demo_messages_processed_total{queue_name="keda-demo-queue"}

# Total messages failed (Counter — split by Python exception type)
keda_demo_messages_failed_total{queue_name="keda-demo-queue", error_type="JSONDecodeError"}

# Processing time histogram (Histogram — bucket-based)
keda_demo_message_processing_duration_seconds_bucket{queue_name="keda-demo-queue"}

# Pod active/idle gauge (Gauge — 0 or 1, changes direction)
keda_demo_consumer_active  # 1=processing, 0=polling empty queue

# SQS API errors (Counter — split by AWS error code)
keda_demo_sqs_poll_errors_total{error_code="Throttling"}
```

### Useful PromQL Queries

```promql
# Processing throughput (messages/second over last 5 minutes)
rate(keda_demo_messages_processed_total[5m])

# Success rate percentage
rate(keda_demo_messages_processed_total[5m])
/
(rate(keda_demo_messages_processed_total[5m]) + rate(keda_demo_messages_failed_total[5m]))
* 100

# P50, P95, P99 latency
histogram_quantile(0.50, rate(keda_demo_message_processing_duration_seconds_bucket[5m]))
histogram_quantile(0.95, rate(keda_demo_message_processing_duration_seconds_bucket[5m]))
histogram_quantile(0.99, rate(keda_demo_message_processing_duration_seconds_bucket[5m]))

# Active pods ratio (across all consumer replicas)
sum(keda_demo_consumer_active) / count(keda_demo_consumer_active)
```

### Accessing Metrics Directly

```bash
# Port-forward to a consumer pod's :8080 to see raw metrics
kubectl port-forward pod/<consumer-pod-name> 8080:8080 -n keda-demo
curl http://localhost:8080/metrics | grep keda_demo

# Example output:
# HELP keda_demo_messages_processed_total Total number of SQS messages successfully processed
# TYPE keda_demo_messages_processed_total counter
# keda_demo_messages_processed_total{queue_name="keda-demo-queue"} 142.0
```

---

## 3. KEDA Metrics (from Operator)

```promql
# Current queue depth KEDA is observing (the key scaling metric)
keda_scaler_metrics_value{scaledObject="keda-demo", namespace="keda-demo"}

# Is the scaler active? (1=queue non-empty, 0=empty)
keda_scaler_active{namespace="keda-demo"}

# Scaling errors (should always be 0 in healthy operation)
keda_scaler_error_total{namespace="keda-demo"}

# Combine: show queue depth vs pod count side-by-side
# Panel 1: keda_scaler_metrics_value (queue depth)
# Panel 2: kube_deployment_spec_replicas (desired pods)
# Panel 3: kube_deployment_status_replicas_ready (ready pods)
```

---

## 4. Alert Rules (PrometheusRule)

Defined in [`manifests/prometheus-rules.yaml`](../manifests/prometheus-rules.yaml).

### Alert Summary

| Alert | Severity | Trigger | Action |
|---|---|---|---|
| `KedaDemoProcessingStalled` | 🔴 critical | Queue>5 msgs, pods running, 0 processing for 5m | Check logs, IRSA, network |
| `KedaDemoHighFailureRate` | 🟡 warning | >10% failure rate for 5m | Check DLQ, error_type label |
| `KedaDemoSlowProcessing` | 🟡 warning | P99 > 5s for 10m | Check CPU/memory pressure |
| `KedaDemoDLQNotEmpty` | 🔴 critical | Any message in DLQ for 5m | Fix bug, redrive DLQ |
| `KedaDemoQueueGrowing` | 🟡 warning | Queue growing for 15m | Increase maxReplicaCount |
| `KEDAScalerErrors` | 🔴 critical | KEDA scaler errors for 5m | Check IRSA, KEDA logs |
| `KEDAScaledObjectPaused` | 🟡 warning | ScaledObject paused >30m | Unpause or acknowledge |

### Checking Alert Status

```bash
# See all alerts in Prometheus UI:
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# → http://localhost:9090/alerts

# See all alerts in Alertmanager:
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring
# → http://localhost:9093

# Query alert state via API:
curl http://localhost:9090/api/v1/alerts | python -m json.tool
```

---

## 5. Alertmanager Routing (Stub)

Alertmanager routes firing alerts to notification channels.
To add Slack notifications, add to Alertmanager config:

```yaml
# Add to kube-prometheus-stack Helm values (terraform/modules/monitoring/main.tf):
set {
  name  = "alertmanager.config.receivers[0].name"
  value = "slack"
}
set {
  name  = "alertmanager.config.receivers[0].slack_configs[0].api_url"
  value = "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
}
set {
  name  = "alertmanager.config.receivers[0].slack_configs[0].channel"
  value = "#keda-demo-alerts"
}
```

---

## 6. Full Observability Runbook

### Scenario: "Queue is growing but pods aren't scaling"

```bash
# Step 1: Check KEDA scaler status
kubectl describe scaledobject keda-demo-scaledobject -n keda-demo | grep -A10 "Conditions:"

# Step 2: Check KEDA scaler errors in Prometheus
# Query: increase(keda_scaler_error_total{namespace="keda-demo"}[10m])

# Step 3: Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator --tail=100 | grep -i error

# Step 4: Check IRSA token validity
kubectl exec -n keda-demo <pod-name> -- env | grep AWS_ROLE_ARN
```

### Scenario: "Processing stalled — messages accumulating"

```bash
# Step 1: Look at alert KedaDemoProcessingStalled in Prometheus
# Step 2: Check consumer logs
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=50

# Step 3: Check raw metrics endpoint
kubectl port-forward pod/<pod> 8080:8080 -n keda-demo
curl http://localhost:8080/metrics | grep -E 'processed|failed|poll_errors'

# Step 4: Verify SQS connectivity
kubectl exec -n keda-demo <pod> -- python -c "
import boto3
sqs = boto3.client('sqs', region_name='us-east-1')
print(sqs.get_queue_attributes(QueueUrl='YOUR_URL', AttributeNames=['All']))
"
```
