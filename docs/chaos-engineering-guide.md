# Chaos Engineering Guide: Resilience Testing for SmartScale AI

Chaos engineering is the practice of intentionally injecting failures
into a system to discover weaknesses before they cause production incidents.
This guide covers the resilience properties of the KEDA SQS consumer and
how to verify them with the chaos test tools provided.

---

## 1. The Chaos Engineering Model

```
Traditional approach (hope-based reliability):
  "We think the system is resilient"
  Discover failure modes during production incidents

Chaos engineering approach (evidence-based reliability):
  "We hypothesize the system is resilient — let's test it"
  Discover failure modes in controlled experiments before incidents
```

**The four steps for each experiment:**

1. **Define steady state** — what does normal look like? (queue draining, pods running)
2. **Hypothesize** — "During [failure], the system will maintain [behavior]"
3. **Inject** — create the failure in a controlled way
4. **Observe and validate** — did the hypothesis hold? Pass or Fail?

---

## 2. Resilience Properties Under Test

### Property 1: Scale-to-Zero Safety
**Claim:** When the SQS queue empties, all consumer pods terminate cleanly.

**Why it could fail:** PodDisruptionBudget blocks pod eviction. KEDA ScaledObject
is paused. cooldownPeriod is set too long.

**Test:** `bash scripts/chaos-test.sh --experiment scale-to-zero`

**Expected behavior:**
```
Queue depth = 0
→ KEDA reads 0 messages (next poll, 15s)
→ HPA sets desiredReplicas = 0
→ Kubernetes sends SIGTERM to all consumer pods
→ app.py _handle_sigterm() sets _running = False
→ Current receive_message() poll completes (≤ 20s)
→ Health file removed → pod NotReady
→ Pod exits cleanly
→ Kubernetes sees desiredReplicas = 0 satisfied
```

---

### Property 2: Pod Kill Recovery
**Claim:** If a consumer pod is killed (OOMKilled, node failure, manual delete),
KEDA reschedules a replacement within 90 seconds.

**Why it could fail:** KEDA is not polling. The replacement pod is stuck in
Pending (no available nodes). Node has anti-affinity preventing placement.

**Test:** `bash scripts/chaos-test.sh --experiment pod-kill`

**Expected behavior:**
```
kubectl delete pod consumer-xyz --force
→ Pod evicted immediately
→ KEDA detects queue still has messages on next poll (≤15s)
→ HPA desired = ceil(N/5), current = 0 → scale up
→ Kubernetes scheduler places new pod
→ Pod passes startupProbe (6 × 5s = 30s max)
→ New pod starts receiving from SQS queue
```

**SQS message fate:**
- In-flight message (invisible in SQS): visibility timeout (30s) expires
- Message becomes visible again → new pod receives and processes it
- One message may be processed twice → acceptable if workload is idempotent

---

### Property 3: Transient Network Failure
**Claim:** If the consumer temporarily cannot reach SQS (DNS failure, network
partition), it retries with backoff and does NOT crash.

**Why it could fail:** Unhandled exception propagates out of the run() loop.
Python `botocore` raises `EndpointResolutionError` which is not caught.

**Test:** `bash scripts/chaos-test.sh --experiment network-partition`

**Expected behavior:**
```
DNS blocked → SQS API call fails with BotoCoreError or EndpointResolutionError
→ app.py except clause catches exception
→ SQS_POLL_ERRORS counter incremented (error_code = BotoCoreError)
→ time.sleep(5)  ← backoff before retry
→ Loop continues (self._running is still True)
→ DNS restored → next SQS poll succeeds
→ Processing resumes normally
```

**Unit test:** `pytest application/chaos_test.py::TestErrorHandlingAndRetry::test_sqs_client_error_does_not_crash_consumer`

---

### Property 4: Spot Node Interruption
**Claim:** When a Spot node is reclaimed by AWS (2-minute warning via
instance metadata), consumer pods migrate to other nodes within 120 seconds.

**Why it could fail:** No other nodes available (min_size too low). Pod
anti-affinity prevents placement. Cluster Autoscaler too slow to add nodes.

**Test:** `bash scripts/chaos-test.sh --experiment spot-interruption`

**Spot interruption sequence:**
```
t=0    aws-node-termination-handler detects interruption notice
t=0    NTH cordons node: kubectl cordon <node>
t=0    NTH drains node: kubectl drain --grace-period=40
t=0    Kubernetes sends SIGTERM to pods on draining node
t=40   Pods finish in-flight messages, exit cleanly
t=40   K8s scheduler places pods on remaining uncordoned nodes
t=120  Cluster Autoscaler provisions replacement Spot node
t=300  New Spot node joins cluster, available for scheduling
```

---

### Property 5: Queue Flood (Scale-Up Speed)
**Claim:** A sudden surge of 25 messages triggers scale-up to 5 pods
within 120 seconds.

**Why it could fail:** KEDA scaler errors (IRSA expiry). Quota prevents
pod creation. Insufficient node capacity (CA hasn't added nodes yet).

**Test:** `bash scripts/chaos-test.sh --experiment queue-flood`

**Scale-up timeline:**
```
t=0    25 messages sent to SQS
t=15   KEDA polls SQS: depth = 25, desired = ceil(25/5) = 5
t=15   KEDA updates HPA: desiredReplicas = 5
t=20   Kubernetes schedules 5 pods (if node capacity available)
t=40   Pods pass startupProbe (5 × 5s attempts)
t=45   5 pods actively consuming from SQS queue
```

---

## 3. Running Chaos Tests

### Option A: Unit Tests (Fast, No Cluster Needed)

```bash
cd application
pip install -r requirements-dev.txt

# Run all chaos unit tests
pytest chaos_test.py -v

# Run specific category
pytest chaos_test.py::TestSigtermGracefulShutdown -v

# With coverage
pytest chaos_test.py --cov=app --cov-report=term-missing
```

These run in ~3 seconds with zero AWS infrastructure.

### Option B: Shell Chaos Tests (Full Cluster Required)

```bash
# Prerequisites: kubectl configured, cluster running
export QUEUE_URL=$(terraform output -raw sqs_queue_url)

# Dry run first (shows what would execute, no changes)
bash scripts/chaos-test.sh --dry-run

# Run all experiments sequentially
bash scripts/chaos-test.sh

# Run one experiment
bash scripts/chaos-test.sh --experiment queue-flood

# Watch cluster in parallel (another terminal)
watch -n 5 kubectl get pods -n keda-demo
```

### Option C: Continuous GameDay (Manual Runbook)

Run during a planned "GameDay" session with the team:

```
Duration: 30-60 minutes
Participants: 1 operator (running experiments) + 1 observer (watching dashboards)

Step 1 [0:00]  Open Grafana dashboard (kubectl port-forward to Grafana)
Step 2 [0:05]  Verify steady state: queue empty, 0 pods, no alerts firing
Step 3 [0:10]  Experiment 4 (queue-flood): send 25 messages, verify 5 pods scale up
Step 4 [0:20]  Experiment 1 (pod-kill): kill a pod, verify recovery
Step 5 [0:30]  Experiment 2 (scale-to-zero): drain queue, verify 0 pods
Step 6 [0:40]  Experiment 5 (spot-interruption): drain a node, verify migration
Step 7 [0:50]  Review Prometheus metrics, check for unexpected errors
Step 8 [0:60]  Document findings, file issues for any failures
```

---

## 4. What Each Test Validates in Code

| Experiment | Code Path Exercised | Alert Triggered |
|---|---|---|
| Pod kill | `_handle_sigterm()` → health file removal | `KedaDemoProcessingStalled` if recovery fails |
| Scale to zero | `KEDA cooldownPeriod` → HPA `desiredReplicas=0` | `KEDAScaledObjectPaused` if stuck |
| Network partition | `except (ClientError, BotoCoreError)` → `SQS_POLL_ERRORS.inc()` | `KEDAScalerErrors` |
| Queue flood | KEDA `ceil(N/targetQueueLength)` math | `KedaDemoQueueGrowing` if flood sustained |
| Spot interruption | `terminationGracePeriodSeconds=40` honored | `KedaDemoProcessingStalled` during migration |

---

## 5. Interpreting Results

```
PASS: All expected behaviors confirmed → system is resilient for this failure mode
FAIL: Unexpected behavior observed → file a bug, fix before production

Common failure patterns and their fixes:
┌──────────────────────────────────┬──────────────────────────────────────┐
│ Failure Observation              │ Root Cause + Fix                      │
├──────────────────────────────────┼──────────────────────────────────────┤
│ Pod kill → no recovery in 90s   │ KEDA scaler stopped (IRSA expired)    │
│                                  │ Fix: check keda-operator logs          │
├──────────────────────────────────┼──────────────────────────────────────┤
│ Scale-to-zero doesn't happen     │ cooldownPeriod too high, or PDB block  │
│                                  │ Fix: kubectl describe scaledobject     │
├──────────────────────────────────┼──────────────────────────────────────┤
│ Consumer crashes on network err  │ Unhandled exception type in run()     │
│                                  │ Fix: add except clause for that type   │
├──────────────────────────────────┼──────────────────────────────────────┤
│ Queue flood → <5 pods in 120s    │ Insufficient node capacity             │
│                                  │ Fix: CA min_size=1 or pre-scale nodes  │
├──────────────────────────────────┼──────────────────────────────────────┤
│ Spot drain → pods not rescheduled│ No other schedulable nodes available   │
│                                  │ Fix: ensure min On-Demand nodes >= 1   │
└──────────────────────────────────┴──────────────────────────────────────┘
```
