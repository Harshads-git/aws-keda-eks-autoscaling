# Dashboard Guide — SmartScale AI Live Demo

Real-time web dashboard for monitoring KEDA autoscaling in action.

---

## 1. What the Dashboard Shows

```
┌──────────────────────────────────────────────────────────────┐
│  ⚡ SmartScale AI                          [LIVE]  Refreshing │
├──────────────────┬──────────────────┬───────────────────────┤
│  Priority Queue  │  Consumer Pods   │  AI Predictor         │
│                  │                  │                       │
│  ████████ 23     │  ████████ 8/10   │  Model: arima         │
│  messages        │  ready/desired   │  Confidence: 0.87     │
├──────────────────┼──────────────────┤                       │
│  Batch Queue     │                  │                       │
│  ████ 5          │                  │                       │
│  messages        │                  │                       │
├──────────────────┴──────────────────┴───────────────────────┤
│  Demo Trigger     [20] messages  [Priority ▾]  [Send Messages]│
├─────────────────────────────────────────────────────────────┤
│  Scale Events                                                │
│  19:30:22  ScaleUp    1 → 8 pods   Depth exceeded threshold │
│  19:28:01  ScaleDown  8 → 1 pods   Queue drained            │
└─────────────────────────────────────────────────────────────┘
```

**Status colours:**
- 🟢 Green card — queue empty (0 messages), pods healthy
- 🟡 Amber card — queue has 1-9 messages (scaling likely imminent)
- 🔴 Red pulsing — queue ≥ 10 messages (active scaling happening)

---

## 2. Quick Start

```bash
# Step 1: Deploy all SmartScale AI services
kubectl apply -f manifests/

# Step 2: Verify dashboard pod is running
kubectl get pods -n keda-demo -l app.kubernetes.io/name=dashboard
# NAME                         READY   STATUS    AGE
# dashboard-xxxxxxxxx-xxxxx    1/1     Running   30s

# Step 3: Port-forward the dashboard
kubectl port-forward -n keda-demo svc/dashboard 8092:8092 &

# Step 4: Open in browser
# http://localhost:8092
```

---

## 3. HTMX Architecture

The dashboard uses **HTMX** for partial page updates without a JavaScript framework:

```
Browser                           Dashboard Server (FastAPI)
  │                                         │
  │  GET / (initial load)                   │
  │────────────────────────────────────────▶│
  │  ◀─────── Full HTML page + HTMX script ──│
  │                                         │
  │  Every 3 seconds:                       │
  │  GET /fragments/stats                   │
  │────────────────────────────────────────▶│  Fetch SQS depth
  │                                         │  Read K8s pod counts
  │                                         │  Call prediction-api /model/info
  │  ◀──── HTML fragment (stat cards only) ──│
  │  (HTMX swaps innerHTML of #stats div)   │
  │                                         │
  │  GET /fragments/events                  │
  │────────────────────────────────────────▶│  Read in-memory event buffer
  │  ◀──── HTML fragment (events table) ────│
```

Key HTMX attributes used:
```html
<!-- Auto-refresh every 3s -->
<div hx-get="/fragments/stats"
     hx-trigger="load, every 3s"
     hx-swap="innerHTML">

<!-- Submit form via HTMX POST, show result inline -->
<button hx-post="/api/send-bulk"
        hx-include="#msg-count, #msg-queue"
        hx-target="#send-result"
        hx-swap="innerHTML">
```

Why HTMX beats WebSockets for this use case:
- No persistent connection to manage (simpler, more reliable)
- Works behind HTTP load balancers and proxies without special config
- Gracefully degrades if JavaScript is unavailable

---

## 4. Running the Demo

### Full Autoscaling Demo via Dashboard

1. **Open** `http://localhost:8092` — all cards should show green (0 messages, 1 pod)

2. **Send a burst** using the Demo Trigger:
   - Set count to **30**, queue: **Priority**
   - Click **Send Messages**
   - Card turns amber then red as depth increases

3. **Watch pods scale** — Consumer Pods card updates from `1/1` → `8/10` → `10/10`

4. **Wait** 2-3 minutes — as consumers drain the queue:
   - Priority Queue card returns to green (0 messages)
   - Consumer Pods card scales back to `1/1`

5. **Check Scale Events** table — should show ScaleUp and ScaleDown entries

### Recording Scale Events

The dashboard has a `/api/event` endpoint for external tools to push scale events:

```bash
# Record a scale-up event (call from monitoring scripts or KEDA webhook)
curl -X POST "http://localhost:8092/api/event" \
  -G \
  --data-urlencode "event_type=ScaleUp" \
  --data-urlencode "from_pods=1" \
  --data-urlencode "to_pods=8" \
  --data-urlencode "reason=Depth exceeded threshold"
```

---

## 5. Data Sources

| Panel | Source | Fallback |
|---|---|---|
| Priority Queue Depth | SQS `GetQueueAttributes` | Shows `?` if SQS unreachable |
| Batch Queue Depth | SQS `GetQueueAttributes` | Shows `?` if SQS unreachable |
| Consumer Pods | Kubernetes API `AppsV1.list_namespaced_deployment` | Empty if k8s unreachable |
| AI Predictor | `GET http://prediction-api:8090/model/info` | Shows `—` if API unreachable |
| Scale Events | In-memory ring buffer (max 20, shows last 5) | Shows "No events yet" |
| Demo Trigger | `POST http://producer-api:8091/send/bulk` | Error message shown inline |

---

## 6. Configuration

| Env Variable | Default | Description |
|---|---|---|
| `DASHBOARD_PORT` | `8092` | HTTP port to bind |
| `REFRESH_INTERVAL_SECONDS` | `3` | HTMX polling interval |
| `PRIORITY_QUEUE_URL` | from `SQS_QUEUE_URL` | SQS priority queue URL |
| `BATCH_QUEUE_URL` | from `SQS_QUEUE_URL` | SQS batch queue URL |
| `PREDICTION_API_URL` | `http://prediction-api...:8090` | Prediction API service URL |
| `PRODUCER_API_URL` | `http://producer-api...:8091` | Producer API service URL |
| `POD_NAMESPACE` | `keda-demo` | Namespace to query for pod counts |

---

## 7. Customising the Dashboard

### Change Refresh Rate

```bash
# Slower refresh (10 seconds) — less load on SQS/K8s API
kubectl set env deployment/dashboard -n keda-demo REFRESH_INTERVAL_SECONDS=10
```

### Add a New Stat Card

Edit `_render_stats_fragment()` in `dashboard.py`:

```python
# Add inside the stats-grid div
f"""
<div class="stat-card status-ok">
  <div class="stat-label">My Custom Metric</div>
  <div class="stat-value">{my_value}</div>
  <div class="stat-sub">description</div>
</div>
"""
```

Then rebuild and push the image:
```bash
docker build -t keda-demo-app:latest ./application
kubectl rollout restart deployment/dashboard -n keda-demo
```
