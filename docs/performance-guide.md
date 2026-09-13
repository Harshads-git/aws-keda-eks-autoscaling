# Performance Guide: Latency Targets, SLOs, and Benchmarking

This guide defines the performance targets (SLOs) for SmartScale AI,
explains how to measure them, and shows how to interpret results.

---

## 1. Service Level Objectives (SLOs)

| Metric | SLO Target | Alert Threshold | Tool to Measure |
|---|---|---|---|
| Scale-up lag (burst) | ≤ 45s end-to-end | > 60s sustained | `scripts/load-test.sh` |
| P99 processing latency | ≤ 5s per message | > 5s for > 1min | `scripts/benchmark.sh` |
| Error rate | < 1% of messages | ≥ 1% for > 5min | `scripts/benchmark.sh` |
| Scale-to-zero time | ≤ 360s after queue empties | Stuck > 10 min | `scripts/chaos-test.sh` |
| Pod recovery after kill | ≤ 90s | > 90s | `scripts/chaos-test.sh` |

> **SLO vs SLA**: These are internal SLOs (objectives). An SLA (agreement) with external parties would be derived from these, with a safety margin.

---

## 2. The Scale-Up Lag Budget

When a traffic spike arrives, every second before pods are Ready is a second
where messages wait in the queue unprocessed. Here is where the time goes:

```
t=0    Messages arrive in SQS (queue depth 0 → N)

t=0–15 KEDA polling gap (pollingInterval=15s)
       KEDA may have just polled → must wait up to 15s for next poll
       Best case: 1s (just missed the poll) | Worst case: 15s

t=15   KEDA detects depth > 0 → updates HPA desiredReplicas
       HPA controller loop latency: ~1–2s

t=17   Kubernetes scheduler places pod on available node
       Scheduling latency: 1–5s (node ready, resource available)

t=22   Pod starts: container image pulled (skip: already cached on node)
       imagePullPolicy: Always → re-validates tag, does NOT re-pull if digest matches
       Pull latency: ~0s if cached | ~30s if cold (new node, first deploy)

t=22   startupProbe begins: initialDelaySeconds=5, periodSeconds=5, failureThreshold=6
       Health file /tmp/healthy must exist → written at startup in 0.1s
       startupProbe passes at t=22+5=27s (first attempt)

t=27   Pod is Ready → starts receiving from SQS

Total (best case):  1 + 1 + 1 + 0 + 5 = 8s
Total (worst case): 15 + 2 + 5 + 0 + 5 = 27s
SLO target:         45s (includes buffer for slow scheduling, registry pull)
```

### How Predictive Scaling Eliminates This Lag

```
Reactive (current):   0s → detect → 8–27s → pods ready
Predictive (ai/):     -5min → predicted → pods warm → 0s lag on spike
```

See [`docs/ai-scaling-guide.md`](ai-scaling-guide.md) for the predictor details.

---

## 3. Running the Benchmarks

### Step 1: Measure processing latency (no cluster needed)

```bash
cd application
pytest performance_test.py -v -s

# Expected output:
#   📊 Typical Payload (order.created)
#        N=200  avg=1.20ms  p50=1.10ms  p95=2.30ms  p99=3.50ms  ±0.40ms
#        Throughput: 830.2 calls/sec
```

### Step 2: Measure end-to-end scale-up timing (cluster needed)

```bash
export QUEUE_URL=$(terraform output -raw sqs_queue_url)

# Burst test: 25 messages at once, measure time to 5 ready pods
bash scripts/load-test.sh --scenario burst --count 25

# Expected output:
#   Elapsed  Queue Depth  Running  Ready
#   5s       25           0        0
#   10s      25           1        0
#   20s      22           3        0
#   30s      15           5        3
#   40s      8            5        5     ← all ready
#   ✓ SLO: PASS (40s ≤ 45s)
```

### Step 3: Measure live Prometheus metrics

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &

# Run benchmark
bash scripts/benchmark.sh

# Expected output:
#   ── Processing Latency ──
#     P50 (median) latency:       1.2ms
#     P95 latency:                2.8ms
#     P99 latency:                4.1ms
#   ✓ P99 SLO: PASS (4.1s ≤ 5.0s)
```

### Step 4: Before/After comparison (for optimizations)

```bash
bash scripts/benchmark.sh --snapshot before
# (make your code change)
bash scripts/benchmark.sh --snapshot after
bash scripts/benchmark.sh --compare

#   Metric               Before    After     Change
#   P50 latency          1.2ms     0.9ms     ↓ 25.0%
#   P99 latency          4.1ms     2.3ms     ↓ 43.9%
```

---

## 4. Interpreting Results

### If P99 latency is high (> 5s)

```
1. Run performance_test.py:
   PASS (P99 < 50ms):  Python is NOT the bottleneck → look at SQS or network
   FAIL (P99 > 50ms):  Python IS the bottleneck → profile with cProfile

2. Profile process_message():
   python -m cProfile -s cumulative -m pytest performance_test.py::TestSingleMessageThroughput

3. Common causes:
   - Expensive JSON parsing (use orjson for 3x speedup)
   - Synchronous HTTP calls inside process_message()
   - Logging too much at INFO level (switch to WARNING in prod)
```

### If scale-up lag exceeds 45s

```
Diagnose with these kubectl commands:

# Is KEDA polling correctly?
kubectl describe scaledobject keda-demo-scaledobject -n keda-demo
# Look for: "ScalingActive: True", last poll timestamp

# Is IRSA working? (KEDA needs SQS access)
kubectl logs -n keda -l app=keda-operator --tail=30 | grep -i "error\|denied"

# Are pods stuck in Pending? (node capacity)
kubectl get events -n keda-demo --sort-by='.lastTimestamp' | grep -i "pending\|scheduling"

# Is the image being pulled fresh? (cold node)
kubectl describe pod -n keda-demo -l app.kubernetes.io/name=keda-demo | grep "Pulling\|Pulled"
```

### If error rate is high (> 1%)

```
# Check what's failing
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=50 | grep ERROR

# Check DLQ depth (if messages are failing repeatedly)
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --attribute-names ApproximateNumberOfMessages

# Check Prometheus for failure pattern
bash scripts/benchmark.sh  # Error rate section
```

---

## 5. Performance Tuning Knobs

| Parameter | Location | Effect on Performance |
|---|---|---|
| `SQS_MAX_MESSAGES` (1→10) | `configmap.yaml` | 10x throughput per pod, reduces KEDA accuracy |
| `pollingInterval` (15→5) | `keda-scaled-object.yaml` | Faster scale-up detection, 3x SQS API calls |
| `WaitTimeSeconds` (20→0) | `configmap.yaml` | Short-polling: faster latency, 20x more SQS API calls |
| `maxReplicaCount` (5→10) | `keda-scaled-object.yaml` | Higher peak throughput, more cost |
| `resources.cpu.limit` | `deployment.yaml` | Avoids CPU throttling under burst (set 500m in prod) |

> **Warning:** Increasing `SQS_MAX_MESSAGES > 1` breaks the KEDA scaling formula. KEDA assumes 1 message per pod. With 10 messages: KEDA requests 10x too many pods. Only change with matching `targetQueueLength` update.
