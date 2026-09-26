# Multi-Queue Architecture Guide

This guide covers SmartScale AI's multi-queue support: running a single KEDA-scaled
consumer Deployment that processes two SQS queues with priority routing.

---

## 1. Why Multiple Queues?

A single queue works well for homogeneous workloads. Multi-queue adds:

| Benefit | Single Queue | Multi-Queue |
|---|---|---|
| **Priority routing** | ❌ All messages equal | ✅ High-priority processed first |
| **Independent scaling** | One trigger | Two triggers, MAX logic |
| **Different SLOs** | One latency target | Priority: < 2s, Batch: best effort |
| **Traffic isolation** | Bursts affect all | Batch slows, priority unaffected |
| **Observability** | Mixed metrics | Separate counters per queue type |

**SmartScale AI use case:**
- **Priority queue:** Payment confirmations, fraud alerts, user-facing events.
  These need to start processing within 2 seconds of arrival.
- **Batch queue:** Analytics aggregation, report generation, cache warming.
  These can wait during priority traffic spikes.

---

## 2. KEDA Multi-Trigger Scaling Logic

The KEDA `ScaledObject` in `manifests/multi-queue-scaled-object.yaml` has two triggers:

```
priority_queue_depth = 20  →  desiredReplicas = ceil(20 / 2)  = 10
batch_queue_depth    = 30  →  desiredReplicas = ceil(30 / 10) = 3

KEDA selects MAX(10, 3) = 10 replicas
```

KEDA uses **OR logic (MAX)** across all triggers — not AND, not SUM.
This means a spike on either queue drives scaling up, and both queues
benefit from the extra pod capacity.

### Trigger Configuration Comparison

| Parameter | Priority Trigger | Batch Trigger |
|---|---|---|
| `queueLength` | **2** (aggressive) | **10** (conservative) |
| `scaleOnInFlight` | `true` (count in-flight) | `false` (backlog only) |
| Scale for 20 messages | 10 pods | 2 pods |
| Scale for 100 messages | 10 pods (capped) | 10 pods |

---

## 3. Consumer Priority-First Algorithm

Each pod runs `application/multi_queue_consumer.py` which implements:

```
LOOP:
  1. Poll PRIORITY queue
     → Messages found? Process ALL of them. GO TO 1.
     → Empty? Continue to step 2.
  2. Poll BATCH queue
     → Messages found? Process all. GO TO 1.
     → Empty? Sleep 1s. GO TO 1.
```

### Priority-First vs Round-Robin

```
Scenario: 10 priority messages + 20 batch messages in queue, 2 pods

Priority-First:
  t=0s:  Both pods drain priority queue (10 msgs ÷ 2 pods = 5 each)
  t=5s:  Priority empty → both pods start batch processing
  t=25s: All 20 batch messages processed
  Priority SLA: ✅ All priority messages done by t=5s

Round-Robin (50/50):
  t=0s:  Each pod alternates priority/batch messages
  t=15s: Priority messages done (mixed in with batch processing)
  t=25s: All batch done
  Priority SLA: ❌ Priority messages dragged out to t=15s
```

### Batch Starvation Risk

If the priority queue never empties, batch messages wait indefinitely.

**Mitigation strategies:**
1. **Admission control:** Allow 1 batch message per N priority messages
   (add a counter to `_poll_cycle()`: `if priority_count % 10 == 0: process_one_batch()`).
2. **Separate Deployments:** Run a small dedicated batch consumer (1 pod)
   alongside the multi-queue consumer. Priority pod handles spikes; batch pod
   provides steady-state throughput.
3. **Queue TTL:** Set SQS `MessageRetentionPeriod` on batch queue to alert
   when messages exceed age threshold (CloudWatch alarm: `ApproximateAgeOfOldestMessage > 3600s`).

---

## 4. Deployment

### Step 1: Apply manifests

```bash
# Deploy the multi-queue consumer Deployment
# (Edit manifests/multi-queue-deployment.yaml with your queue URLs first)
kubectl apply -f manifests/multi-queue-scaled-object.yaml

# Verify ScaledObject is created
kubectl get scaledobject -n keda-demo
# NAME                    ACTIVE   READY
# keda-demo-multi-queue   True     True
```

### Step 2: Send test messages

```python
import boto3

sqs = boto3.client("sqs", endpoint_url="http://localhost:9324")

# Send 5 priority messages
for i in range(5):
    sqs.send_message(
        QueueUrl="http://local-sqs:9324/.../keda-demo-queue-priority",
        MessageBody=f'{{"type":"priority","id":{i}}}',
    )

# Send 20 batch messages
for i in range(20):
    sqs.send_message(
        QueueUrl="http://local-sqs:9324/.../keda-demo-queue-batch",
        MessageBody=f'{{"type":"batch","job_id":{i}}}',
    )
```

### Step 3: Watch KEDA scale

```bash
# Watch replica count change based on combined queue depth
kubectl get deployment keda-demo-multi-queue -n keda-demo -w

# View per-queue metrics
kubectl port-forward -n keda-demo svc/keda-demo-multi-queue 8080:8080 &
curl http://localhost:8080/metrics | grep mq_

# Expected metrics:
# mq_priority_messages_processed_total 5
# mq_batch_messages_processed_total 20
# mq_priority_queue_depth 0
# mq_batch_queue_depth 0
```

---

## 5. Monitoring

### Grafana Queries

```promql
# Priority processing rate (msgs/min)
rate(mq_priority_messages_processed_total[1m]) * 60

# Batch processing rate (msgs/min)
rate(mq_batch_messages_processed_total[1m]) * 60

# Priority-to-batch ratio (should be < 1 at steady state)
rate(mq_priority_messages_processed_total[5m])
  /
rate(mq_batch_messages_processed_total[5m])

# P99 priority processing duration
histogram_quantile(0.99, rate(mq_priority_processing_duration_seconds_bucket[5m]))

# Batch starvation alert: batch queue depth increasing while priority processing
mq_batch_queue_depth > 100 and rate(mq_priority_messages_processed_total[5m]) > 0
```

---

## 6. Comparison: KEDA Multi-Trigger vs AWS SQS Redrive

| Approach | KEDA Multi-Trigger | SQS Priority via Redrive |
|---|---|---|
| **Priority mechanism** | Consumer software (priority-first loop) | Separate queues + separate consumers |
| **Scaling** | One ScaledObject, MAX across triggers | One ScaledObject per queue |
| **Cost** | One Deployment, shared pods | Two Deployments, isolated pods |
| **Complexity** | Medium (consumer routing logic) | Lower (no routing needed) |
| **Starvation risk** | Yes (needs mitigation) | No (dedicated consumer) |
| **Best for** | Cost-conscious teams, < 10 pods | Large-scale, strict priority SLAs |
