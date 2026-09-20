# Distributed Tracing Guide: OpenTelemetry + Jaeger

This guide covers the SmartScale AI distributed tracing architecture:
how traces are generated, collected, and visualized for debugging.

---

## Why Distributed Tracing?

Logs answer: **"What happened?"**
Metrics answer: **"How much/how often?"**
Traces answer: **"How long did each step take, and in what order?"**

When a message takes 10 seconds to process, tracing shows you exactly where
the time was spent:

```
Total: 10.2s
├── SQS ReceiveMessage:   0.8s (network to SQS)
├── Parse body:           0.001s (instant)
├── Business logic:       9.0s (← THE BOTTLENECK)
├── Update metrics:       0.001s (instant)
└── SQS DeleteMessage:    0.4s (network to SQS)
```

Without tracing, you'd see "P99 = 10s" in Prometheus but have no idea
which part of the pipeline is slow.

---

## Architecture

```
┌────────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Consumer Pod  │     │  OTel Collector   │     │   Jaeger UI  │
│                │     │                   │     │              │
│  tracing.py    │────▶│  Receive (OTLP)   │────▶│  Store       │
│  creates spans │gRPC │  Process (batch)  │gRPC │  Query       │
│  per message   │:4317│  Export (Jaeger)   │     │  Visualize   │
│                │     │                   │     │  :16686      │
└────────────────┘     └──────────────────┘     └──────────────┘
                             │
                       memory_limiter
                       resource enrichment
                       batch processor
```

---

## Span Hierarchy

Each SQS message creates one **trace** with this span tree:

```
smartscale.poll_cycle (root span — one polling iteration)
│
├── aws.sqs.ReceiveMessage (auto-instrumented by botocore)
│   ├── Attributes:
│   │   ├── aws.service: "sqs"
│   │   ├── aws.operation: "ReceiveMessage"
│   │   ├── aws.region: "us-east-1"
│   │   └── aws.request_id: "abc-123"
│   └── Duration: time waiting for SQS to respond
│
├── smartscale.process_message (custom span from app.py)
│   ├── Attributes:
│   │   ├── message_id: "msg-456"
│   │   ├── trace_id: "a1b2c3d4e5f6"
│   │   ├── receive_count: 1
│   │   └── body_length: 42
│   ├── Events:
│   │   ├── "message_parsed" (timestamp when JSON parsing completed)
│   │   └── "processing_complete" (timestamp when business logic finished)
│   └── Status: OK or ERROR (with exception details)
│
└── aws.sqs.DeleteMessage (auto-instrumented by botocore)
    ├── Attributes:
    │   ├── aws.service: "sqs"
    │   └── aws.operation: "DeleteMessage"
    └── Duration: time for SQS to confirm deletion
```

---

## Setup

### Step 1: Deploy Jaeger + OTel Collector

```bash
# Apply the combined manifest
kubectl apply -f monitoring/otel-collector.yaml

# Verify both are running
kubectl get pods -n monitoring -l app=jaeger
kubectl get pods -n monitoring -l app=otel-collector

# Wait for both to be Ready
kubectl wait --for=condition=Ready pod -l app=jaeger -n monitoring --timeout=60s
kubectl wait --for=condition=Ready pod -l app=otel-collector -n monitoring --timeout=60s
```

### Step 2: Enable Tracing in Consumer Pods

Add these environment variables to the consumer Deployment:

```yaml
env:
  - name: OTEL_ENABLED
    value: "true"
  - name: OTEL_EXPORTER_ENDPOINT
    value: "http://otel-collector.monitoring.svc.cluster.local:4317"
  - name: OTEL_SERVICE_NAME
    value: "smartscale-consumer"
```

### Step 3: Access Jaeger UI

```bash
# Port-forward Jaeger
kubectl port-forward -n monitoring svc/jaeger 16686:16686 &

# Open in browser
# URL: http://localhost:16686
```

---

## Using Jaeger UI

### Finding Traces

1. **Service dropdown:** Select `smartscale-consumer`.
2. **Operation dropdown:** Select `smartscale.poll_cycle` (root span).
3. **Lookback:** Set to `Last Hour` for recent traces.
4. Click **Find Traces**.

### Reading a Trace

Each row in the trace list shows:
- **Duration:** Total time for the root span.
- **Spans:** Number of child spans (3+ per message).
- **Errors:** Red dot if any span has an error status.

Click a trace to see the waterfall view:
- Horizontal bars = span duration (longer = slower).
- Nested bars = parent-child relationship.
- Red bars = error spans (click to see exception details).

### Debugging Performance

**Scenario:** P99 latency is 10 seconds (SLO is 5 seconds).

1. In Jaeger, find traces with `minDuration: 5s`.
2. Open the slowest trace.
3. Look at the waterfall: which span is the widest?
   - `aws.sqs.ReceiveMessage` is wide → SQS or network latency.
   - `smartscale.process_message` is wide → application code.
   - `aws.sqs.DeleteMessage` is wide → SQS throttling.

**Scenario:** Messages failing intermittently.

1. Search with `tag: error=true`.
2. Open an error trace.
3. The error span has a logged exception with stack trace.
4. Cross-reference the `trace_id` with application logs:
   ```bash
   kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo \
     | jq 'select(.trace_id == "a1b2c3d4e5f6")'
   ```

---

## Connecting Traces, Logs, and Metrics

The three observability pillars are linked by shared identifiers:

```
                ┌──────────────┐
                │   trace_id   │
                │  "a1b2c3..."  │
                └──────┬───────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
    ┌─────▼─────┐ ┌───▼────┐ ┌────▼─────┐
    │   Traces  │ │  Logs  │ │ Metrics  │
    │  (Jaeger) │ │(kubectl│ │(Grafana) │
    │           │ │  /CW)  │ │          │
    │ Waterfall │ │ JSON   │ │ P99      │
    │ view      │ │ lines  │ │ graph    │
    └───────────┘ └────────┘ └──────────┘
```

| Signal | Tool | Find by trace_id |
|---|---|---|
| **Traces** | Jaeger UI | Search → Tags → `trace_id=a1b2c3...` |
| **Logs** | kubectl + jq | `jq 'select(.trace_id == "a1b2c3...")'` |
| **Metrics** | Grafana | Correlate timestamp on P99 graph with trace time |

---

## Configuration Reference

| Environment Variable | Default | Description |
|---|---|---|
| `OTEL_ENABLED` | `"false"` | Set `"true"` to enable tracing |
| `OTEL_EXPORTER_ENDPOINT` | `"http://localhost:4317"` | OTel Collector gRPC endpoint |
| `OTEL_SERVICE_NAME` | `"smartscale-consumer"` | Service name shown in Jaeger |

---

## OTel Collector vs Direct Export

| Approach | Pros | Cons |
|---|---|---|
| **App → Jaeger directly** | Simple, fewer components | Tight coupling, no processing |
| **App → OTel Collector → Jaeger** | Decoupled, can batch/sample/fan-out | Extra deployment |

We use the Collector because:
1. Adding X-Ray export later = 1 config change (no app code change).
2. Memory limiter protects the node from trace data storms.
3. Resource processor adds cluster metadata without app changes.

---

## Sampling (Production)

In production, tracing every single message is expensive. Use sampling:

```yaml
# In OTel Collector config:
processors:
  probabilistic_sampler:
    sampling_percentage: 10  # Trace 10% of requests
```

- **10% sampling:** Reduces trace volume 10x while still catching patterns.
- **Always sample errors:** Use tail-based sampling to keep 100% of error traces.
- **Local development:** Keep 100% sampling (low volume, every trace matters).
