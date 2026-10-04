# Producer API Guide — SmartScale AI

REST API for injecting SQS messages to trigger KEDA autoscaling demos
and load testing the SmartScale AI consumer pipeline.

---

## 1. Overview

The Producer API is the entry point for the SmartScale AI demo. It accepts
HTTP requests and sends messages to the SQS queues that drive KEDA autoscaling.

```
Load Tester / curl
      │  POST /send/bulk {"count": 50}
      ▼
Producer API (port 8091)
      │  SQS SendMessageBatch (10 msgs per call)
      ▼
ElasticMQ (local) / AWS SQS
      │  ApproximateNumberOfMessages = 50
      ▼
KEDA ScaledObject polls depth every 30s
      │  desiredReplicas = ceil(50 / targetQueueLength=2) = 25
      │  capped at maxReplicaCount=10
      ▼
keda-demo Deployment → 10 pods
      │  5 msgs/pod processed, depth drops
      ▼
KEDA scales back to 1 pod (cooldown period)
```

---

## 2. API Reference

**Base URL (after port-forward):** `http://localhost:8091`

### GET /health

Liveness probe. Always returns 200 if the process is running.

```bash
curl http://localhost:8091/health
# {"status": "ok"}
```

---

### POST /send

Send a single message to the priority or batch queue.

**Request body:**
```json
{
  "body": "{\"event\": \"order.created\", \"order_id\": \"abc-123\"}",
  "queue_type": "priority",
  "message_id": "optional-dedup-key"
}
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `body` | string | Yes | — | Message body (any string) |
| `queue_type` | string | No | `"priority"` | `"priority"` or `"batch"` |
| `message_id` | string | No | auto-generated UUID | Idempotency key |

**Response:**
```json
{
  "message_id": "abc-123-sqs-id",
  "queue_type": "priority",
  "queue_url": "http://local-sqs.keda-demo.svc.cluster.local:9324/000000000000/keda-demo-queue-priority",
  "send_duration_ms": 2.4
}
```

---

### POST /send/bulk

Send N messages to trigger KEDA autoscaling. **Primary demo trigger.**

**Request body:**
```json
{
  "count": 50,
  "queue_type": "priority",
  "body_template": "{\"event\": \"demo\", \"index\": {index}}"
}
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `count` | int | Yes | — | 1–500 messages |
| `queue_type` | string | No | `"priority"` | `"priority"` or `"batch"` |
| `body_template` | string | No | `{"event": "demo", "index": {index}}` | `{index}` is replaced with 0, 1, 2, ... |

**Response:**
```json
{
  "sent": 50,
  "failed": 0,
  "queue_type": "priority",
  "total_duration_ms": 124.7
}
```

**Implementation detail:** Uses `SendMessageBatch` with 10 messages per API call
(maximum allowed by SQS). 50 messages = 5 API calls. 10x more efficient than
50 individual `SendMessage` calls.

---

### GET /queue/depth

Get current message depth of both queues (for monitoring dashboards).

```bash
curl http://localhost:8091/queue/depth
```

```json
{
  "priority_queue_depth": 45,
  "batch_queue_depth": 12,
  "total_depth": 57,
  "priority_queue_url": "http://...:9324/.../keda-demo-queue-priority",
  "batch_queue_url": "http://...:9324/.../keda-demo-queue-batch"
}
```

---

### GET /metrics

Prometheus text format metrics.

```
# HELP producer_messages_sent_total Total messages sent to SQS
producer_messages_sent_total{queue_type="priority"} 50.0
producer_messages_sent_total{queue_type="batch"} 12.0

# HELP producer_messages_failed_total Total messages that failed to send
producer_messages_failed_total{queue_type="priority"} 0.0

# HELP producer_send_latency_seconds Time to send a single message to SQS
producer_send_latency_seconds_bucket{queue_type="priority",le="0.01"} 48.0

# HELP producer_bulk_send_size Number of messages per bulk send request
producer_bulk_send_size_bucket{le="50.0"} 3.0

# HELP producer_priority_queue_depth ApproximateNumberOfMessages in priority queue
producer_priority_queue_depth 45.0
```

---

## 3. Quick Start (Local Demo)

```bash
# 1. Port-forward the producer API
kubectl port-forward -n keda-demo svc/producer-api 8091:8091 &

# 2. Check it's alive
curl http://localhost:8091/health

# 3. Check current queue depth
curl http://localhost:8091/queue/depth

# 4. Trigger KEDA demo: send 30 messages to priority queue
curl -X POST http://localhost:8091/send/bulk \
  -H "Content-Type: application/json" \
  -d '{"count": 30, "queue_type": "priority"}'

# 5. Watch pods scale up (in another terminal)
kubectl get pods -n keda-demo -w

# 6. Wait ~2 minutes and watch them scale back down
```

---

## 4. Load Testing with curl Loop

```bash
# Send 10 bursts of 20 messages with 5s intervals
for i in $(seq 1 10); do
  curl -s -X POST http://localhost:8091/send/bulk \
    -H "Content-Type: application/json" \
    -d "{\"count\": 20, \"queue_type\": \"priority\"}" \
    | python3 -m json.tool
  sleep 5
done
```

---

## 5. Queue Routing

| `queue_type` | Queue | Consumer | KEDA ScaledObject |
|---|---|---|---|
| `priority` | keda-demo-queue-priority | `multi_queue_consumer.py` | `multi-queue-scaled-object.yaml` |
| `batch` | keda-demo-queue-batch | `multi_queue_consumer.py` | `multi-queue-scaled-object.yaml` |
| *(default)* | Falls back to `SQS_QUEUE_URL` | `app.py` | `scaled-object.yaml` |

**Priority routing:** The multi-queue consumer always drains the priority queue
first before processing batch messages (implemented in `multi_queue_consumer.py`).
Use `priority` for time-sensitive events and `batch` for bulk/background work.

---

## 6. Prometheus Alert Rules

```yaml
# Add to monitoring/prometheus-rules.yaml
- alert: ProducerHighFailureRate
  expr: rate(producer_messages_failed_total[5m]) > 0.05
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Producer API failure rate above 5%"
    description: "Check SQS connectivity and queue URL configuration."

- alert: QueueDepthSpiking
  expr: producer_priority_queue_depth > 100
  for: 1m
  labels:
    severity: warning
  annotations:
    summary: "Priority queue depth > 100"
    description: "KEDA should be scaling consumers. Check ScaledObject status."
```
