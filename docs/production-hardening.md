# Production Hardening Guide

This guide explains the production-readiness features added to the KEDA demo
deployment: resource limits, health probes, PodDisruptionBudgets, and topology
spread constraints. Each section explains the **what**, **why**, and **what
happens without it**.

---

## 1. Resource Limits and Requests

Defined in [`manifests/deployment.yaml`](../manifests/deployment.yaml).

```yaml
resources:
  requests:
    cpu: "50m"      # 5% of 1 vCPU — guaranteed by scheduler
    memory: "64Mi"  # 64MB guaranteed
  limits:
    cpu: "200m"     # 20% of 1 vCPU — hard burst ceiling
    memory: "128Mi" # 128MB hard ceiling (OOMKilled if exceeded)
```

### What they do

| Field | Kubernetes effect |
|---|---|
| `requests.cpu` | Scheduler uses this to find a node with enough free CPU |
| `requests.memory` | Scheduler uses this to find a node with enough free RAM |
| `limits.cpu` | Linux cgroups throttle CPU beyond this — pod slows, not killed |
| `limits.memory` | Linux OOM killer terminates the container if exceeded |

### Without resource limits

```
Node RAM: 1GB (t3.micro allocatable: ~900MB)

Pod A: memory leak grows to 500MB
Pod B: memory grows to 400MB
─────────────────────────────
Total: 900MB → node OOM → kernel kills random process (may be kubelet itself)
→ node goes NotReady → ALL pods on node evicted → queue processing stops
```

### With limits

```
Pod A: memory limit 128MB → pod OOMKilled at 128MB → pod restarts (isolated)
Pod B: unaffected — other pods' limits protect it
Node: stays healthy
```

### Node capacity planning (t3.micro = ~900MB allocatable)

```
1 consumer pod:  128MB limit    (×5 pods = 640MB)
KEDA operator:  ~128MB
kube-proxy:     ~32MB
node-exporter:  ~64MB
Total:          ~864MB of 900MB   ← very tight on t3.micro
```

> Use `t3.small` (2GB) if enabling monitoring (adds ~500MB).

---

## 2. Three-Tier Health Probes

```
Pod start                    t=5s     t=10s     t=35s+
───────────────────────────────────────────────────────────────
startupProbe                  │◄───── checks every 5s ─────►│ → succeeds → hands off
liveness  (disabled)          ×       ×         ✓ now active
readiness (disabled)          ×       ×         ✓ now active
```

### Startup Probe (added Day 18)

```yaml
startupProbe:
  exec:
    command: ["python", "-c", "import os, sys; sys.exit(0 if os.path.exists('/tmp/healthy') else 1)"]
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 6   # 30 seconds max
```

**Purpose**: blocks liveness/readiness until the container finishes starting.

**Without it**: On a cold node with slow ECR pull + Python import time:
1. Pod starts at `t=0`
2. Liveness fires at `t=10` (initialDelaySeconds) — `/tmp/healthy` doesn't exist yet
3. K8s marks liveness as failed → restarts pod → infinite CrashLoopBackOff

**With startup probe**: liveness is blocked for up to 30s. `/tmp/healthy` is
created by `app.py` after its first successful SQS connection. Once the startup
probe passes, normal probing begins.

### Liveness Probe

```yaml
livenessProbe:
  initialDelaySeconds: 10
  periodSeconds: 30
  failureThreshold: 3  # Restart after 3 consecutive failures (90s)
```

**Purpose**: detects if the consumer is frozen (e.g., stuck in a deadlock or infinite loop).

**Without it**: A frozen pod stays in the deployment indefinitely, consuming
memory and a scheduling slot, but processing zero messages.

### Readiness Probe

```yaml
readinessProbe:
  periodSeconds: 10
  failureThreshold: 2  # Remove from "ready" after 2 failures (20s)
```

**Purpose**: removes an unhealthy pod from active processing before K8s restarts it.

**KEDA interaction**: KEDA's HPA only assigns work to `Ready` pods. A pod that
fails readiness will not receive new messages — it finishes its current message
then stops.

---

## 3. PodDisruptionBudget

Defined in [`manifests/pdb.yaml`](../manifests/pdb.yaml).

```yaml
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: keda-demo
```

### Voluntary vs Involuntary Disruptions

| Type | Example | PDB protects? |
|---|---|---|
| **Voluntary** | CA node drain, `kubectl drain`, rolling update | ✅ Yes |
| **Involuntary** | EC2 hardware failure, OOMKill, kernel panic | ❌ No |

### Without PDB

```
CA: "node ip-10-0-3-5 is underutilized, draining..."
  → evicts pod-1 ✓
  → evicts pod-2 ✓
  → evicts pod-3 ✓
  → evicts pod-4 ✓
  → evicts pod-5 ✓   ← all 5 pods gone simultaneously

5 messages in-flight → become invisible for 30s (visibility timeout)
After 30s: redelivered → reprocessed = DUPLICATE PROCESSING
```

### With PDB (maxUnavailable: 1)

```
CA: "node ip-10-0-3-5 is underutilized, draining..."
  → evicts pod-1 ✓ → waits for pod-1 to reschedule on another node
  → pod-1 rescheduled → evicts pod-2 ✓ → waits...
  → (repeats for all pods, one at a time)

Queue processing continues throughout — at least 4 pods running always.
```

### PDB + KEDA Scale-to-Zero

When KEDA scales to 0 pods (queue empty), the PDB is automatically suspended.
Kubernetes does not enforce `maxUnavailable` when `desiredReplicas < maxUnavailable`.

CA can drain the node freely when the queue is empty — PDB only applies when
there is active work being processed.

---

## 4. Topology Spread Constraints

Defined in [`manifests/deployment.yaml`](../manifests/deployment.yaml).

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: keda-demo
```

### Without topology spread

```
5 consumer pods, 2 nodes in 2 AZs:
  Node-A (us-east-1a): [pod1, pod2, pod3, pod4, pod5]
  Node-B (us-east-1b): []

AZ-a outage → all 5 pods gone → queue processing stops for ~45s (pod restart)
```

### With topology spread (maxSkew: 1)

```
5 pods, 2 AZs:
  Node-A (us-east-1a): [pod1, pod2, pod3]
  Node-B (us-east-1b): [pod4, pod5]

AZ-a outage → 3 pods gone, 2 pods still running
Queue processing continues at 40% capacity during the outage
```

### `whenUnsatisfiable: ScheduleAnyway` (soft constraint)

This project uses `ScheduleAnyway` instead of `DoNotSchedule` because:
- On a single-node dev cluster: there is only 1 AZ → perfect spread is impossible
- `DoNotSchedule` would leave all pods Pending (cluster broken for development)
- `ScheduleAnyway`: best-effort spread, always schedules

In production with 3+ nodes across 2+ AZs: effective spread is achieved
automatically with `ScheduleAnyway`.

---

## 5. Production Readiness Checklist

```
☑ Resource requests/limits on all containers
☑ startupProbe (prevents CrashLoopBackOff on cold nodes)
☑ livenessProbe (restarts frozen consumers)
☑ readinessProbe (removes unhealthy pods from processing)
☑ PodDisruptionBudget (protects against CA drain)
☑ terminationGracePeriodSeconds: 40 (finish current message before shutdown)
☑ topologySpreadConstraints (AZ-aware pod distribution)
☑ securityContext: runAsNonRoot, readOnlyRootFilesystem, drop ALL caps
☑ IRSA (no static AWS credentials)
☑ SQS visibility timeout < terminationGracePeriodSeconds (avoid duplicates)

Still to add (future days):
☐ Horizontal Pod Autoscaler (KEDA manages this)
☐ Network Policy (restrict pod-to-pod traffic)
☐ Pod Security Standards (namespace enforced in namespace.yaml)
☐ Prometheus alerts for KEDA errors and DLQ messages
```
