# Demo Guide: Live Presentation of SmartScale AI

This guide covers how to run a live demonstration of the system,
what to say at each stage, and what the evaluator will observe.

---

## Before the Demo: Setup Checklist

Run this **10 minutes before** presenting:

```bash
# 1. Confirm cluster is running
kubectl get nodes
# Expected: 2+ nodes in Ready state

# 2. Confirm KEDA is operational
kubectl get pods -n keda | grep keda-operator
# Expected: keda-operator pod Running

# 3. Confirm the consumer deployment exists
kubectl get deployment keda-demo -n keda-demo
# Expected: deployment.apps/keda-demo  0/0 ready (scale-to-zero)

# 4. Confirm ScaledObject is active
kubectl describe scaledobject keda-demo-scaledobject -n keda-demo | grep -A5 "Status:"
# Expected: ScalingActive: True, DesiredReplicas: 0

# 5. Confirm queue is empty
export QUEUE_URL=$(terraform output -raw sqs_queue_url)
aws sqs get-queue-attributes --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages
# Expected: ApproximateNumberOfMessages = 0

# 6. Open Grafana in browser (optional)
kubectl port-forward -n monitoring svc/grafana 3000:3000 &
# Open: http://localhost:3000
```

---

## Option A: Automated Demo (Recommended for Presentations)

```bash
export QUEUE_URL=$(terraform output -raw sqs_queue_url)
bash scripts/demo.sh
```

The script runs all 5 phases with narration, timing tables, and SLO gates.
Let the script run — talk to the narration lines (marked with ▶).

**For a time-constrained demo** (skip the 5-minute scale-to-zero wait):
```bash
bash scripts/demo.sh --skip-phase 4
```

**Dry-run rehearsal** (no cluster needed — just to practice talking points):
```bash
bash scripts/demo.sh --dry-run
```

---

## Option B: Manual Step-by-Step Demo

### Step 1 — Show the Steady State (1 minute)

**You say:**
> *"Right now, the SQS queue has zero messages. Because KEDA's minReplicaCount is zero, there are literally no consumer pods running — and no compute cost. Watch what happens when traffic arrives."*

```bash
# Terminal 1: live pod watcher
watch -n 3 "kubectl get pods -n keda-demo && echo '' && kubectl get hpa -n keda-demo"

# Terminal 2: queue depth
aws sqs get-queue-attributes --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible
```

**Evaluator sees:** 0 pods, 0 messages. Deployment exists but is at 0/0.

---

### Step 2 — Send Messages and Watch Scale-Up (3 minutes)

**You say:**
> *"I'll send 25 messages at once — a sudden burst. KEDA polls SQS every 15 seconds. When it sees 25 messages, it applies the formula: ceil(25 ÷ 5) = 5 pods. Let's see how long the scale-up takes."*

```bash
# Send 25 messages
bash scripts/load-test.sh --scenario burst --count 25

# In Terminal 1: watch pods appear (0 → 5)
```

**Expected timeline:**
```
t=0s   Messages sent
t=5s   Queue depth = 25 (SQS eventually consistent)
t=15s  KEDA polls: detects depth=25, updates HPA desiredReplicas=5
t=20s  Kubernetes scheduler places 5 pods
t=40s  startupProbe passes: /tmp/healthy exists → pods marked Ready
t=40s  Pods start receiving from SQS
```

**Evaluator sees:** 5 pods appear within ~40 seconds. SLO gate output from load-test.sh.

---

### Step 3 — Show Messages Being Processed (2 minutes)

**You say:**
> *"Each pod is now long-polling SQS — waiting up to 20 seconds for a message. When one arrives, it processes the JSON payload, records the latency to a Prometheus histogram, then calls delete_message with the receipt handle. If delete_message fails, SQS re-delivers the message after 30 seconds — that's the at-least-once guarantee."*

```bash
# Watch a live consumer pod log
kubectl logs -n keda-demo \
  -l app.kubernetes.io/name=keda-demo \
  --follow --tail=20

# Show Prometheus metrics from a pod
kubectl exec -n keda-demo \
  $(kubectl get pods -n keda-demo -l app.kubernetes.io/name=keda-demo -o name | head -1) \
  -- curl -s http://localhost:8080/metrics | grep keda_demo
```

**Evaluator sees:**
- Structured JSON log lines with `event`, `message_id`, `duration_ms`
- Prometheus metrics: `keda_demo_messages_processed_total` incrementing
- `keda_demo_message_processing_duration_seconds_bucket` updating

---

### Step 4 — Show Scale-to-Zero (explain, don't wait) (1 minute)

**You say:**
> *"Once the queue empties, KEDA waits for cooldownPeriod — 300 seconds in production — before scaling back to zero. This prevents thrashing if traffic returns briefly. After 5 minutes: no messages, no pods, no cost. For a demo I'll skip the wait, but you can verify with `kubectl get pods -n keda-demo --watch`."*

```bash
# Show ScaledObject status after queue drains
kubectl describe scaledobject keda-demo-scaledobject -n keda-demo | grep -A 10 "Status:"
```

---

### Step 5 — Show the AI Predictive Scaling (2 minutes)

**You say:**
> *"The reactive KEDA baseline is good, but has a 40-second lag. SmartScale AI adds a predictive layer. The scikit-learn model in ai/predictor.py observes queue depth every 15 seconds and uses linear regression to forecast 5 minutes ahead. When it predicts a spike, the KEDA External Scaler pre-warms the pods before messages arrive. Let me run the predictor demo."*

```bash
cd ai && python predictor.py
```

**Evaluator sees:** Side-by-side table: `Reactive replicas` vs `Predictive replicas` with confidence score.

---

### Step 6 — Show the Observability Stack (1 minute)

**You say:**
> *"Every consumer pod exposes Prometheus metrics on port 8080. Prometheus scrapes all pods via a Headless Service — if we used a ClusterIP service, only one pod would be scraped. We have 7 alert rules: stalled processing, high failure rate, KEDA errors, DLQ depth. If P99 latency exceeds 5 seconds, Alertmanager fires a notification."*

```bash
# If Grafana is port-forwarded: open http://localhost:3000
# Show: queue depth panel, pod count panel, P99 latency panel

# Or show the PromQL directly:
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
bash scripts/benchmark.sh
```

---

## Key Numbers to Know (Memorise These)

| Question | Answer |
|---|---|
| "How fast does it scale up?" | 8–40 seconds (depends on KEDA poll timing) |
| "What's the KEDA formula?" | ceil(queue_depth / 5) pods, max 5 |
| "How many pods at peak?" | 5 (configurable via maxReplicaCount) |
| "What happens to messages if a pod dies?" | Visibility timeout (30s) → SQS re-delivers |
| "How much does it cost to run?" | EKS: ~$0.10/hr (t3.micro nodes) + SQS: ~$0.40/1M messages |
| "Why Spot instances?" | 70–90% cheaper than On-Demand for fault-tolerant workloads |
| "How is AWS auth handled?" | IRSA: OIDC token → STS AssumeRoleWithWebIdentity → temp credentials |
| "What if the AI predictor is wrong?" | Confidence < 0.5 → falls back to reactive KEDA (safe default) |

---

## Q&A Answers

**Q: "Why KEDA instead of just Kubernetes HPA?"**
> HPA requires a metrics server and works on CPU/memory. KEDA extends HPA to work on external metrics — SQS queue depth, Redis length, Kafka lag. Zero consumer pods when queue is empty is only possible with KEDA (HPA minimum is 1).

**Q: "Why not just use AWS Lambda for this?"**
> Lambda is excellent for simple event processing. KEDA on EKS is better when: (a) you need long-running processes (Lambda 15-min limit), (b) you have existing Kubernetes infrastructure, (c) you need predictable latency (no cold starts with minReplicaCount=1), (d) you want full container control (custom runtimes, dependencies).

**Q: "How does IRSA work?"**
> The EKS pod identity webhook injects two environment variables into the pod: `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`. Boto3 detects these and calls `sts:AssumeRoleWithWebIdentity` with the Kubernetes service account token. STS returns 1-hour temporary credentials. No static keys are stored anywhere.

**Q: "What's the P99 latency?"**
> In testing with the simulated workload: P99 ≈ 2–4ms for `process_message()` in isolation (measured by `application/performance_test.py`). End-to-end SLO target is ≤5s per message including SQS receive time.
