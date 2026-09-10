# AI Predictive Scaling Guide: SmartScale AI

This guide explains the AI predictive scaling component, how it relates to
the reactive KEDA baseline, and the roadmap for integrating it into production.

---

## 1. Reactive vs Predictive Scaling: The Core Problem

```
Timeline: A traffic spike arrives at t=0

Reactive (current KEDA SQS trigger):
  t=0    Messages start arriving in SQS queue
  t=15   KEDA polls SQS: depth = 12 → desiredReplicas = ceil(12/5) = 3
  t=15   Kubernetes scheduler places 3 pods
  t=40   Pods pass startupProbe (5s × 6 attempts)
  t=40   3 pods start consuming → queue backlog builds for 40 seconds

Predictive (ai/predictor.py):
  t=-5min Predictor observes rising queue trend: predicts depth=12 in 5 min
  t=-5min KEDA external scaler returns metric=12 → desiredReplicas = 3
  t=-4min 3 pods start, pass startupProbe
  t=0    Traffic spike arrives → 3 pods ALREADY RUNNING → no lag
  t=0    Queue drains immediately
```

**Benefit of predictive scaling: eliminates the ~40s pod startup lag** during
traffic spikes. For high-throughput applications, this 40-second window can
mean thousands of unprocessed messages.

---

## 2. Model Architecture

### Current Implementation: Linear Regression with Rolling Window Features

```
Input: sequence of queue depth observations (every 15 seconds)
         [2, 3, 4, 7, 9, 12, ...]  ← last N observations

Feature engineering (build_features()):
  current_depth  = most recent observation (primary signal)
  lag_1, lag_2   = previous 2 values (autocorrelation)
  rolling_mean   = average over last 5 values (trend direction)
  rolling_std    = std dev over last 5 values (traffic volatility)
  delta_1        = current - lag_1 (velocity: queue growing/shrinking)
  delta_2        = lag_1 - lag_2 (acceleration: rate of change)

Model: sklearn.linear_model.LinearRegression
  X = [current_depth, lag_1, lag_2, rolling_mean, rolling_std, delta_1, delta_2]
  y = queue_depth at t + horizon_steps
  horizon_steps = 5 min × 60s / 15s = 20 steps ahead

Output:
  predicted_depth: estimated queue depth 5 minutes from now
  recommended_replicas: ceil(predicted_depth × 1.2 / 5)  ← 20% buffer
  confidence: R²-based score [0.0, 1.0]
```

### Why Linear Regression (not deep learning)?

| Factor | Linear Regression | LSTM / Transformer |
|---|---|---|
| Training data needed | 10-50 samples | 1,000+ samples |
| Training time | Milliseconds | Minutes to hours |
| Interpretability | High (coefficients) | Low (black box) |
| Overfitting risk | Low | High with small data |
| Good for | Demo + early days | Production with months of data |

**When to upgrade to LSTM:** After 2-3 months of production data (thousands
of observations), retrain with a sequence model (PyTorch LSTM or Facebook Prophet).

---

## 3. Integration with KEDA

The predictor plugs into KEDA via the **External Scaler** protocol:

```
┌─────────────────────────────────────────────────────────────────┐
│  PredictiveExternalScaler (ai/keda_external_scaler_stub.py)     │
│                                                                 │
│  SQS polling loop ──► QueueDepthPredictor.record_observation()  │
│                        QueueDepthPredictor.predict()            │
│                              │                                  │
│  KEDA gRPC calls ◄───────────┘                                  │
│    GetMetricSpec() → "predictedQueueDepth", targetSize=5        │
│    GetMetrics()    → predicted_depth × 1.2 (with buffer)        │
│    IsActive()      → True if predicted > 0 or actual > 0        │
└──────────────────────┬──────────────────────────────────────────┘
                       │ gRPC (port 50051)
                       ▼
                  KEDA Operator
                       │
                       ▼
              HPA desiredReplicas = ceil(metric / targetSize)
                       │
                       ▼
           Consumer Deployment (0–5 pods)
```

### Confidence-Based Fallback

```python
if predictor.confidence >= 0.5:
    return predicted_depth   # AI-driven scaling
else:
    return actual_depth      # Fallback to reactive (safe mode)
```

This ensures the system degrades gracefully:
- Day 1 (10 observations): low confidence → reactive scaling (same as KEDA SQS trigger)
- Week 1 (1,000 observations): high confidence → predictive scaling active

---

## 4. Running the Demo

### Option A: Standalone predictor demo (no cluster needed)

```bash
cd ai
pip install -r requirements.txt
python predictor.py
```

Expected output:
```
🤖 SmartScale AI — Predictive Scaling Demo
═══════════════════════════════════════════════════════
Simulating queue depth: 30-minute traffic ramp-up
 Step    Depth  Predicted   Reactive  Predictive
───────────────────────────────────────────────
   10        4        5.2          1           2  conf=0.45
   20       12       14.8          3           4  conf=0.61
   30       18       20.1          4           5  conf=0.74
   40        8        6.3          2           2  conf=0.78
   ...
```

The "Predictive" column shows pre-warmed replicas before the "Reactive" trigger fires.

### Option B: External scaler demo

```bash
python keda_external_scaler_stub.py
```

Shows GetMetrics() output that KEDA would consume at each polling interval.

---

## 5. Training Data: What We Collect

Every 15 seconds, the external scaler records:
```json
{
  "timestamp": 1725958200.0,
  "depth": 12
}
```

After 1 hour: 240 observations → model R² typically 0.7-0.9 for predictable workloads.

**To view and save training data:**
```python
predictor.save_history("ai/data/queue-history.json")
# File format: [{timestamp: float, depth: int}, ...]
```

---

## 6. Future Roadmap

| Phase | Timeline | Enhancement |
|---|---|---|
| **Phase 1 (Current)** | Day 25 | Linear Regression prototype, External Scaler stub |
| **Phase 2** | Month 2 | Deploy external scaler as K8s Service, collect real data |
| **Phase 3** | Month 3 | Replace LinearRegression with Facebook Prophet (seasonal patterns) |
| **Phase 4** | Month 4 | Adaptive thresholds: auto-tune `targetQueueLength` per time-of-day |
| **Phase 5** | Month 6 | Explainable AI: log "predicted spike because delta_1 > 5 for 3 consecutive steps" |

### Phase 3: Prophet Model (when you have enough data)

```python
# Drop-in replacement for LinearRegression in predictor.py:
from prophet import Prophet
import pandas as pd

df = pd.DataFrame([
    {"ds": pd.Timestamp(obs.timestamp, unit="s"), "y": obs.depth}
    for obs in self._observations
])
model = Prophet(daily_seasonality=True, weekly_seasonality=True)
model.fit(df)
future = model.make_future_dataframe(periods=self.config.horizon_minutes, freq="T")
forecast = model.predict(future)
predicted_depth = forecast["yhat"].iloc[-1]
```

Prophet handles: daily patterns (9AM spike), weekly patterns (Monday vs Sunday),
holidays, and trend changepoints — all automatically.

---

## 7. Comparison to GCP Reference Implementation

| Aspect | GCP Reference (Pub/Sub + GKE) | SmartScale AI (SQS + EKS) |
|---|---|---|
| Queue metric | No built-in depth metric | `ApproximateNumberOfMessages` (direct) |
| Scaling trigger | KEDA + Pub/Sub undelivered messages | KEDA SQS trigger + AI External Scaler |
| Predictive scaling | Not implemented | Linear Regression predictor (this module) |
| Training data | N/A | SQS depth history (auto-collected) |
| Model upgrade path | N/A | Swap LinearRegression → Prophet → LSTM |

**AWS SQS + KEDA is a better foundation for predictive scaling** than GCP Pub/Sub
because SQS provides a direct `ApproximateNumberOfMessages` attribute — a clean
training signal. Pub/Sub requires more complex metric extraction.
