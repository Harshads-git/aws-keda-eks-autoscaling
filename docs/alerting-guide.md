# Alerting Guide: Alert Definitions, Routing, and Runbooks

This guide documents every PrometheusRule alert, how Alertmanager routes
notifications, and the exact steps to resolve each alert.

---

## Alert Inventory

| # | Alert Name | Severity | Fires When | Time Window |
|---|---|---|---|---|
| 1 | `KedaDemoSlowProcessing` | warning | P99 latency > 5s | 1 min |
| 2 | `KedaDemoHighFailureRate` | warning | Error rate ≥ 1% | 5 min |
| 3 | `KedaDemoConsumerDown` | critical | 0 active consumers + queue not empty | 5 min |
| 4 | `KedaDemoDLQDepthHigh` | critical | Any messages in Dead Letter Queue | 5 min |
| 5 | `KedaOperatorErrors` | warning | KEDA operator error rate > 0 | 5 min |
| 6 | `KedaDemoScalingStuck` | warning | Desired ≠ actual replicas | 10 min |
| 7 | `KedaDemoPodRestartLoop` | critical | Pod restart rate > 0 | 5 min |

---

## Notification Routing

```
Prometheus fires alert
        │
        ▼
  Alertmanager receives
        │
        ├── severity: critical ──▶ #smartscale-critical (Slack/Discord)
        │                          group_wait: 10s (fast)
        │                          repeat_interval: 1h
        │                          <!here> mention
        │
        ├── severity: warning ───▶ #smartscale-alerts
        │                          group_wait: 30s
        │                          repeat_interval: 4h
        │
        └── severity: info ──────▶ #smartscale-alerts
                                   group_wait: 1m (slow)
                                   repeat_interval: 12h
```

### Inhibition Rule
When a **critical** alert fires, matching **warning** alerts for the same
`alertname` and `namespace` are suppressed. This prevents noise — if the
consumer is completely down (critical), slow processing warnings are redundant.

---

## Setup: Connecting Slack or Discord

### Option A: Slack
1. Go to [api.slack.com/apps](https://api.slack.com/apps) → Create New App → From Scratch.
2. Enable **Incoming Webhooks** → Add New Webhook to Workspace.
3. Select `#smartscale-alerts` channel → Authorize.
4. Copy the webhook URL.
5. In `monitoring/alertmanager-config.yaml`, replace `WEBHOOK_URL_HERE` with your URL.

### Option B: Discord
1. In your Discord server, go to channel **Settings** → **Integrations** → **Webhooks**.
2. Create a webhook, copy the URL.
3. **Append `/slack`** to the URL:
   ```
   Original:  https://discord.com/api/webhooks/1234567890/TOKEN
   For Alertmanager: https://discord.com/api/webhooks/1234567890/TOKEN/slack
   ```
4. Use this modified URL in `alertmanager-config.yaml`.

### Apply the Configuration
```bash
kubectl create secret generic alertmanager-config \
  --from-file=alertmanager.yaml=monitoring/alertmanager-config.yaml \
  --namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
```

---

## Alert Runbooks

### 1. KedaDemoSlowProcessing

**What it means:** The 99th percentile message processing time exceeds 5 seconds.

**Diagnostic steps:**
```bash
# Step 1: Is the Python code the bottleneck?
cd application && pytest performance_test.py -v -s
# If P99 < 50ms → Python is fast, bottleneck is elsewhere
# If P99 > 50ms → Python is slow, profile process_message()

# Step 2: Check pod CPU throttling
kubectl top pods -n keda-demo
# If CPU is at limit → increase resources.limits.cpu

# Step 3: Check SQS receive latency
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=20 | grep duration_ms
# If receive_message takes > 20s → SQS or network issue
```

**Resolution:** Increase CPU limits, optimize `process_message()`, or reduce `PROCESSING_DELAY_SECONDS`.

---

### 2. KedaDemoHighFailureRate

**What it means:** More than 1% of messages are failing to process.

**Diagnostic steps:**
```bash
# Step 1: Check what's failing
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=50 | grep ERROR

# Step 2: Check DLQ depth (are messages being permanently rejected?)
aws sqs get-queue-attributes --queue-url $DLQ_URL \
  --attribute-names ApproximateNumberOfMessages

# Step 3: Look at a failing message body
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo | grep "body_length"
# body_length=0 → empty messages | very large → payload issue
```

**Resolution:** Fix message format at producer, add input validation, or increase retry logic.

---

### 3. KedaDemoConsumerDown (CRITICAL)

**What it means:** The SQS queue has messages but no consumer pods are running.

**Diagnostic steps:**
```bash
# Step 1: Is KEDA operator running?
kubectl get pods -n keda -l app=keda-operator

# Step 2: Is the ScaledObject paused?
kubectl describe scaledobject -n keda-demo | grep -i paused

# Step 3: Can KEDA access SQS?
kubectl logs -n keda -l app=keda-operator --tail=20 | grep -i "error\|denied"

# Step 4: Are pods stuck in Pending?
kubectl get events -n keda-demo --sort-by='.lastTimestamp' | head -10
```

**Resolution:** Unpause ScaledObject, fix KEDA IRSA permissions, or free node resources.

---

### 4. KedaDemoDLQDepthHigh (CRITICAL)

**What it means:** Messages have failed processing 3 times and landed in the Dead Letter Queue.

**Diagnostic steps:**
```bash
# Step 1: Read messages from the DLQ to understand what failed
aws sqs receive-message --queue-url $DLQ_URL \
  --max-number-of-messages 5 --visibility-timeout 0

# Step 2: Check consumer logs for the failure pattern
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo | grep "receive_count.*3"
```

**Resolution:** Fix the bug causing failures, then redrive DLQ messages back to the main queue.

---

### 5. KedaOperatorErrors

**What it means:** The KEDA operator is encountering errors while polling SQS or managing the HPA.

**Diagnostic steps:**
```bash
# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator --tail=30

# Common errors:
# "AccessDenied" → IRSA role missing sqs:GetQueueAttributes permission
# "QueueDoesNotExist" → wrong queue URL in ScaledObject
# "Timeout" → network policy blocking KEDA → SQS connectivity
```

**Resolution:** Fix IRSA permissions, correct queue URL, or adjust NetworkPolicy rules.

---

### 6. KedaDemoScalingStuck

**What it means:** KEDA requested N replicas but Kubernetes cannot reach that count for 10+ minutes.

**Diagnostic steps:**
```bash
# Step 1: Check if pods are stuck in Pending
kubectl get pods -n keda-demo | grep Pending

# Step 2: Check scheduling events
kubectl describe pod -n keda-demo $(kubectl get pods -n keda-demo -o name | head -1) | grep -A5 Events

# Step 3: Check node capacity
kubectl describe nodes | grep -A5 "Allocated resources"
```

**Resolution:** Reduce resource requests, add more nodes, or increase maxReplicaCount.

---

### 7. KedaDemoPodRestartLoop (CRITICAL)

**What it means:** Consumer pods are crashing and restarting repeatedly.

**Diagnostic steps:**
```bash
# Step 1: Check why pods are crashing
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --previous

# Step 2: Check exit code
kubectl get pods -n keda-demo -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.exitCode}'
# Exit 137 = OOMKilled (increase memory limit)
# Exit 1   = application error (check logs)
# Exit 143 = SIGTERM (normal shutdown, should not repeat)
```

**Resolution:** Fix application crash, increase memory limits (OOMKill), or fix startup probe.

---

## Testing Alerts

Use the simulation script to trigger alerts and verify notifications:

```bash
# Test a single alert
bash scripts/simulate-alert.sh --alert slow

# Test all alerts
bash scripts/simulate-alert.sh --alert all

# Preview without making changes
bash scripts/simulate-alert.sh --alert all --dry-run

# Clean up after testing
bash scripts/simulate-alert.sh --cleanup
```
