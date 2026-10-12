# End-to-End (E2E) Testing Guide — SmartScale AI

Comprehensive guide for executing, debugging, and automating full-stack
end-to-end integration tests for the SmartScale AI autoscaling platform.

---

## 1. Overview & Architecture

The E2E test suite validates the entire event-driven autoscaling cycle across
all decoupled microservices:

```
                  ┌──────────────────────────────┐
                  │      Pytest E2E Suite        │
                  │ (tests/e2e/test_e2e_scaling) │
                  └──────────────┬───────────────┘
                                 │
         ┌───────────────────────┼────────────────────────┐
         │ 1. POST /send/bulk    │ 2. GET /predict        │ 3. GET /api/stats
         ▼                       ▼                        ▼
┌──────────────────┐    ┌──────────────────┐     ┌──────────────────┐
│   Producer API   │    │  Prediction API  │     │  Live Dashboard  │
│    (Port 8091)   │    │   (Port 8090)    │     │   (Port 8092)    │
└────────┬─────────┘    └──────────────────┘     └────────┬─────────┘
         │ SQS SendMessageBatch                           │
         ▼                                                │ Reads Deployments
┌──────────────────┐                                      │ & SQS Queue Depth
│   AWS SQS /      │◀─────────────────────────────────────┘
│   ElasticMQ      │
└────────┬─────────┘
         │ Metrics: ApproximateNumberOfMessages
         ▼
┌──────────────────┐
│  KEDA Controller │──▶ Scales Consumer Deployment (1 → 5 → 10 pods)
└──────────────────┘
```

The test harness exercises both **synchronous component APIs** and
**asynchronous control loops** (SQS queue propagation, KEDA polling, and Kubernetes
pod provisioning).

---

## 2. Test Environment Setup

You can run the E2E tests against three different setups:

### Option A: Local Kubernetes Cluster (Recommended)

When running Docker Desktop / Kind with KEDA and ElasticMQ deployed:

```bash
# 1. Port-forward the three microservices in separate terminals (or background)
kubectl port-forward -n keda-demo svc/prediction-api 8090:8090 &
kubectl port-forward -n keda-demo svc/producer-api 8091:8091 &
kubectl port-forward -n keda-demo svc/dashboard 8092:8092 &

# 2. Verify all port-forwards respond
curl http://localhost:8090/health
curl http://localhost:8091/health
curl http://localhost:8092/health
```

### Option B: Local Microservices (No K8s Cluster Required)

Run the Python services locally on your development machine:

```bash
# Terminal 1: Prediction API
python application/prediction_api.py

# Terminal 2: Producer API
python application/producer_api.py

# Terminal 3: Dashboard
python application/dashboard.py
```

### Option C: CI / Offline Mode

If services are not reachable, the test suite automatically detects offline
endpoints and gracefully marks dependent live-cluster scenarios as **skipped**,
ensuring baseline test suites pass on any environment without failing PR builds.

---

## 3. Configuration & Environment Variables

All settings can be customized using environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `PRODUCER_API_URL` | `http://localhost:8091` | Target endpoint for SQS message producer |
| `PREDICTION_API_URL` | `http://localhost:8090` | Target endpoint for AI scaling recommendations |
| `DASHBOARD_URL` | `http://localhost:8092` | Target endpoint for live web dashboard |
| `E2E_NAMESPACE` | `keda-demo` | Kubernetes namespace hosting consumers |
| `E2E_DEPLOYMENT` | `keda-demo` | Kubernetes consumer deployment name |
| `E2E_TIMEOUT` | `90` | Maximum wait time (seconds) for asynchronous polling |
| `E2E_POLL_INTERVAL` | `2.0` | Polling frequency (seconds) for status checks |

---

## 4. Test Suite Breakdown

The test suite in [`tests/e2e/test_e2e_scaling.py`](../tests/e2e/test_e2e_scaling.py) includes 5 test classes:

### 1. `TestServicesHealth`
- Verifies that `/health` probes return HTTP 200 and `{"status": "ok"}` on all services.
- Acts as a fast preflight check before attempting stateful mutations.

### 2. `TestPredictionAPIIntegration`
- Tests `/predict?queue_depth=N` for both baseline (`depth=0`) and burst loads (`depth=50`).
- Asserts that recommended replicas scale upwards appropriately.
- Inspects `/model/info` to verify ARIMA/Linear Regression model type and readiness.

### 3. `TestProducerAndQueueLifecycle`
- Validates single-message priority routing via `POST /send`.
- Tests bulk message batching via `POST /send/bulk` with `{index}` template interpolation.
- Polls `/queue/depth` until queue depth increment is confirmed.

### 4. `TestDashboardAggregation`
- Tests `/api/stats` to verify that queue depths, pod status, and predictor telemetry are accurately unified.
- Tests server-rendered HTMX fragments (`/fragments/stats`, `/fragments/events`).

### 5. `TestEndToEndAutoscalingCycle`
- Injects a synthetic load spike of 25 messages.
- Verifies AI predictor recommendation increases.
- Polls until queue depth rises and consumer deployment reflects scaled replicas.

---

## 5. Running the Tests

```bash
# Run the entire E2E test suite
pytest tests/e2e/ -v

# Run only health and prediction API checks
pytest tests/e2e/test_e2e_scaling.py -k "Health or Prediction" -v

# Run with custom timeout and target ports
E2E_TIMEOUT=120 PRODUCER_API_URL=http://localhost:8091 pytest tests/e2e/ -v --tb=short
```

### Expected Output

```text
tests/e2e/test_e2e_scaling.py::TestServicesHealth::test_producer_health PASSED      [ 10%]
tests/e2e/test_e2e_scaling.py::TestServicesHealth::test_prediction_health PASSED    [ 20%]
tests/e2e/test_e2e_scaling.py::TestServicesHealth::test_dashboard_health PASSED     [ 30%]
tests/e2e/test_e2e_scaling.py::TestPredictionAPIIntegration::test_prediction_recommendation_scaling PASSED [ 40%]
tests/e2e/test_e2e_scaling.py::TestPredictionAPIIntegration::test_model_info_metadata PASSED [ 50%]
tests/e2e/test_e2e_scaling.py::TestProducerAndQueueLifecycle::test_single_message_priority_send PASSED [ 60%]
tests/e2e/test_e2e_scaling.py::TestProducerAndQueueLifecycle::test_bulk_send_batch_injection PASSED [ 70%]
tests/e2e/test_e2e_scaling.py::TestDashboardAggregation::test_dashboard_api_stats PASSED [ 80%]
tests/e2e/test_e2e_scaling.py::TestDashboardAggregation::test_dashboard_htmx_fragments PASSED [ 90%]
tests/e2e/test_e2e_scaling.py::TestEndToEndAutoscalingCycle::test_full_scaling_loop PASSED [100%]

============================== 10 passed in 14.82s ==============================
```

---

## 6. GitHub Actions CI Integration

You can integrate E2E tests into CI workflows:

```yaml
# .github/workflows/e2e.yml
name: E2E Integration Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test-e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install dependencies
        run: pip install -r application/requirements.txt pytest
      - name: Run E2E Test Suite
        run: pytest tests/e2e/ -v
```

---

## 7. Troubleshooting & FAQ

### Timeout waiting for queue depth increase
- **Cause:** SQS `ApproximateNumberOfMessages` has a short metric collection lag (typically 1–3s on ElasticMQ, up to 10–15s on AWS SQS).
- **Fix:** Increase `E2E_TIMEOUT=120` or verify that `AWS_ENDPOINT_URL` in `producer_api.py` points to the active SQS instance.

### `kubectl port-forward` connection lost
- **Cause:** Background port-forwards can drop if inactive or if pods restart during rollouts.
- **Fix:** Restart port-forwards or run:
  ```bash
  pkill -f "port-forward"
  kubectl port-forward -n keda-demo svc/producer-api 8091:8091 &
  ```

### Pod scaling not detected
- **Cause:** KEDA polling interval (default 30s) or cooldown period.
- **Fix:** In `scaled-object.yaml`, set `pollingInterval: 5` and `cooldownPeriod: 30` for fast local testing cycles.
