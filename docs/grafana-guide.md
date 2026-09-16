# Grafana Dashboard Guide

This guide covers how to import, configure, and use the SmartScale AI
Grafana dashboards for live monitoring and cost analysis.

---

## Available Dashboards

| Dashboard | File | Purpose | Refresh |
|---|---|---|---|
| **SmartScale Overview** | `monitoring/dashboards/smartscale-overview.json` | Real-time scaling, latency, error rate | 5s |
| **Cost Savings** | `monitoring/dashboards/cost-savings.json` | Scale-to-Zero vs Always-On cost comparison | 30s |

---

## Importing Dashboards into Grafana

### Step 1: Access Grafana

```bash
# Local cluster: port-forward the Grafana service
kubectl port-forward -n monitoring svc/grafana 3000:3000 &

# Open in browser
# URL: http://localhost:3000
# Default credentials: admin / prom-operator (kube-prometheus-stack default)
```

### Step 2: Import the Dashboard JSON

1. In Grafana, click the **"+"** icon in the left sidebar → **Import**.
2. Click **"Upload JSON file"**.
3. Select `monitoring/dashboards/smartscale-overview.json`.
4. In the **Prometheus** dropdown, select your Prometheus data source.
5. Click **Import**.
6. Repeat for `cost-savings.json`.

### Step 3: Verify Data Source

If panels show "No data", verify:
```bash
# Check Prometheus is scraping keda-demo pods
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
# Open http://localhost:9090/targets
# Look for: serviceMonitor/keda-demo/keda-demo-metrics → state: UP
```

---

## Dashboard Panels Reference

### SmartScale Overview Dashboard

#### Panel 1: SQS Queue Depth (Live)
```promql
keda_queue_depth{queue_name="keda-demo-queue"}
```
- **What it shows:** Current number of messages in the SQS queue.
- **Why it matters:** KEDA scales based on this number. ceil(depth / 5) = pod count.
- **Thresholds:** Green (< 10) → Yellow (10–20) → Red (> 20).
- **Overlay line:** Shows `depth / 5` — the expected pod count from KEDA's formula.

#### Panel 2: Active Consumer Pods (Gauge)
```promql
count(kube_pod_status_phase{namespace="keda-demo", pod=~"keda-demo-.*", phase="Running"})
  or vector(0)
```
- **Range:** 0 to 5 (matches maxReplicaCount).
- **`or vector(0)`:** Prevents "No data" when scaled to zero (shows 0 instead).
- **Demo tip:** Show this gauge while running `demo-local.ps1` — the needle moves from 0 to 5 and back.

#### Panel 3: HPA Desired vs Actual Replicas
```promql
kube_horizontalpodautoscaler_status_desired_replicas{...}
kube_horizontalpodautoscaler_status_current_replicas{...}
```
- **Gap between lines = scaling lag.** When desired jumps from 0 to 5 but current rises gradually, that's the scheduling + startupProbe delay.
- **If they stay mismatched for > 60s:** Investigate node capacity (are pods stuck in Pending?).

#### Panel 4: Processing Latency (P50 / P95 / P99)
```promql
histogram_quantile(0.99, sum(rate(keda_demo_message_processing_duration_seconds_bucket[5m])) by (le))
```
- **P99 SLO:** ≤ 5 seconds. Legend label includes "(SLO ≤ 5s)" as a visual reminder.
- **Why percentiles, not averages:** An average of 2s hides the fact that 1% of messages take 30s. P99 catches that outlier.

#### Panel 5: Messages Processed vs Failed (Stacked Bar)
```promql
sum(rate(keda_demo_messages_processed_total[5m]))
sum(rate(keda_demo_messages_failed_total[5m]))
```
- **Stacked bars:** Red failures visually stand out against green successes.
- **Healthy:** All green. **Unhealthy:** Any visible red bars.

#### Panel 6: Error Rate % (Single Stat)
```promql
100 * sum(rate(keda_demo_messages_failed_total[5m]))
    / (sum(rate(keda_demo_messages_processed_total[5m]))
     + sum(rate(keda_demo_messages_failed_total[5m])) + 0.001)
```
- **SLO:** < 1%. Green = healthy. Red = investigate DLQ.
- **`+ 0.001`:** Prevents division by zero when no traffic is flowing.

---

### Cost Savings Dashboard

#### Hours at Zero vs Hours Active
- Directly shows how much time the system was idle (0 pods).
- For bursty event-driven workloads, expect 70–90% idle time.

#### Cost Comparison Table
| Strategy | Hourly Rate | Daily (20% active) | Monthly | Annual | Savings |
|---|---|---|---|---|---|
| Always-On (HPA min=1) | $0.0104 | $0.25 | $7.49 | $91 | 0% |
| KEDA Scale-to-Zero | $0.0104 × active hrs | ~$0.05 | ~$1.50 | ~$18 | 80% |
| KEDA + Spot | $0.0031 × active hrs | ~$0.015 | ~$0.45 | ~$5 | 94% |

---

## Using Dashboards During a Demo

### Before the demo starts
1. Open Grafana in a browser tab: `http://localhost:3000`
2. Navigate to the **SmartScale Overview** dashboard.
3. Set time range to **Last 15 minutes**.
4. Show your teacher: "All panels are flat — no traffic, no pods, no cost."

### During the autoscaling demo
1. Run `demo-local.ps1` in your terminal.
2. Switch to the Grafana tab — panels update in real-time:
   - Queue depth spikes from 0 to 25.
   - Pod gauge moves from 0 to 5.
   - Latency lines appear.
   - Messages processed counter increases.
3. After processing completes: everything returns to 0.

### After the demo
1. Switch to the **Cost Savings** dashboard.
2. Show the "Hours at Zero" stat.
3. Point out: "In the last hour, the system was active for only 90 seconds. The remaining 58.5 minutes cost $0.00."
