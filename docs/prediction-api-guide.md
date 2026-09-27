# Prediction API Guide

HTTP API serving AI-based scaling recommendations for SmartScale AI.
Bridges the Python predictive model with KEDA's External Scaler.

---

## 1. Architecture Position

```
SQS Queue ──▶ KEDA polls depth ──▶ GET /predict?queue_depth=N
                                          │
                              prediction-api.keda-demo:8090
                                          │
                              ┌───────────▼────────────┐
                              │  Is model ready?        │
                              │  confidence >= 0.5?     │
                              ├─────────────────────────┤
                              │  YES: AI prediction     │
                              │   predicted_depth → reps│
                              │  NO: Reactive formula   │
                              │   ceil(depth/target)    │
                              └───────────┬─────────────┘
                                          │
                              recommended_replicas ──▶ KEDA
                              sets HPA targetMetricValue
                                          │
                              Kubernetes scales pods
```

---

## 2. API Reference

### `GET /health`
Kubernetes **liveness probe**. Always returns 200 if the Python process is alive.

```json
{"status": "ok"}
```

### `GET /ready`
Kubernetes **readiness probe**. Returns 200 only after the predictor is initialised.

```json
{"status": "ready", "model_type": "linear_regression"}
```
Returns `503` if predictor not yet initialised (pod not ready to serve traffic).

---

### `GET /predict`
**Main endpoint.** Returns an AI-based replica recommendation.

**Query Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `queue_depth` | float | ✅ Yes | Current SQS `ApproximateNumberOfMessages` |

**Response:**
```json
{
  "recommended_replicas": 4,
  "predicted_depth": 18.5,
  "confidence": 0.87,
  "model_type": "linear_regression",
  "used_ai": true,
  "observations_count": 127,
  "horizon_steps": 3
}
```

**Decision logic:**
```
if model.is_ready() and confidence >= CONFIDENCE_THRESHOLD:
    recommended_replicas = AI prediction
    used_ai = true
else:
    recommended_replicas = ceil(queue_depth / TARGET_QUEUE_LENGTH)
    used_ai = false
```

**Example curl calls:**
```bash
# Basic prediction
curl "http://localhost:8090/predict?queue_depth=15"

# Check if AI is being used (used_ai: true/false)
curl "http://localhost:8090/predict?queue_depth=20" | jq '.used_ai, .confidence'
```

---

### `POST /observe`
Record a queue depth observation without returning a prediction.

**Request body:**
```json
{"depth": 20.0, "timestamp": 1727433600.0}
```
(`timestamp` is optional — defaults to current time.)

**Response:**
```json
{"recorded": true, "depth": 20.0, "observation_count": 128, "model_ready": true}
```

Use this to continuously train the model from a background scraper,
even during quiet periods with few /predict calls.

---

### `GET /model/info`
Returns current model configuration and readiness status.

```json
{
  "model_type": "linear_regression",
  "is_ready": true,
  "observation_count": 127,
  "horizon_steps": 3,
  "target_queue_length": 5,
  "max_replicas": 5,
  "confidence_threshold": 0.5
}
```

---

### `GET /metrics`
Prometheus metrics in text exposition format. Scraped automatically by Prometheus
when `prometheus.io/scrape: "true"` annotation is present on the pod.

**Key metrics:**
```
# Prediction request counter (labels: model_type, used_ai)
prediction_api_requests_total{model_type="linear_regression",used_ai="true"} 42

# Prediction latency histogram
prediction_api_latency_seconds_bucket{le="0.005"} 38

# Most recent replica recommendation
prediction_api_recommended_replicas 4

# Model confidence (alert if < 0.5 sustained)
prediction_api_model_confidence 0.87

# Total observations recorded
prediction_api_observations_total 127
```

---

## 3. Deploying the API

```bash
# Deploy to Kubernetes
kubectl apply -f manifests/prediction-api-deployment.yaml

# Verify pod is Running and Ready
kubectl get pods -n keda-demo -l app.kubernetes.io/name=prediction-api

# Port-forward for local testing
kubectl port-forward -n keda-demo svc/prediction-api 8090:8090 &

# Test endpoints
curl "http://localhost:8090/health"
curl "http://localhost:8090/model/info"
curl "http://localhost:8090/predict?queue_depth=15"
```

---

## 4. Switching Models

Change the `MODEL_TYPE` env var in `manifests/prediction-api-deployment.yaml`:

```yaml
- name: MODEL_TYPE
  value: "arima"   # or "linear_regression"
```

Then apply and restart:
```bash
kubectl apply -f manifests/prediction-api-deployment.yaml
kubectl rollout restart deployment/prediction-api -n keda-demo
```

---

## 5. Confidence & Fallback Policy

| Scenario | `used_ai` | `recommended_replicas` |
|---|---|---|
| Model not ready (< 10 obs) | `false` | `ceil(depth / target)` |
| Model ready, confidence ≥ 0.5 | `true` | AI prediction |
| Model ready, confidence < 0.5 | `false` | `ceil(depth / target)` |
| Model throws exception | `false` | `ceil(depth / target)` |

**Alert on sustained low confidence:**
```promql
prediction_api_model_confidence < 0.5
```

Trigger model retrain or switch to ARIMA when this fires for > 10 minutes.

---

## 6. Prometheus Alerting Rules

```yaml
# Alert: AI model is not being used (reactive-only mode)
- alert: SmartScaleAINotUsed
  expr: |
    rate(prediction_api_requests_total{used_ai="true"}[5m]) == 0
    and
    rate(prediction_api_requests_total[5m]) > 0
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "Prediction API falling back to reactive mode for 10+ minutes"

# Alert: High prediction latency
- alert: PredictionAPIHighLatency
  expr: |
    histogram_quantile(0.99, rate(prediction_api_latency_seconds_bucket[5m])) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "P99 prediction API latency > 100ms"
```
