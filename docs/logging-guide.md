# Logging Guide: Structured Logs, Fluent Bit, and CloudWatch

This guide covers the SmartScale AI logging architecture: how logs are
structured, how they're collected, and how to query them for debugging.

---

## Architecture Overview

```
┌──────────────────┐     ┌─────────────────┐     ┌───────────────────┐
│   Consumer Pod   │     │   Fluent Bit     │     │   Log Backend     │
│                  │     │   (DaemonSet)    │     │                   │
│  python-json-    │────▶│  tail ──▶ parse  │────▶│  stdout (local)   │
│  logger writes   │     │  ──▶ enrich ──▶  │     │  CloudWatch (AWS) │
│  to stdout       │     │  forward         │     │  File (archive)   │
└──────────────────┘     └─────────────────┘     └───────────────────┘
```

---

## Log Format Specification

Every log line is a single JSON object with these fields:

### Core Fields (always present)
| Field | Type | Source | Example |
|---|---|---|---|
| `asctime` | string | python-json-logger | `"2026-09-19T20:00:00"` |
| `name` | string | Logger name | `"keda-demo"` |
| `levelname` | string | Log level | `"INFO"`, `"ERROR"`, `"WARNING"` |
| `message` | string | Log message | `"Processing message"` |

### Pod Metadata (injected by PodMetadataFilter)
| Field | Type | Source | Example |
|---|---|---|---|
| `pod_name` | string | `POD_NAME` env / Downward API | `"keda-demo-7f8b9c-x4k2p"` |
| `node_name` | string | `NODE_NAME` env / Downward API | `"ip-10-0-1-100.ec2.internal"` |
| `namespace` | string | `POD_NAMESPACE` env / Downward API | `"keda-demo"` |

### Message Processing Fields (contextual)
| Field | Type | When | Example |
|---|---|---|---|
| `trace_id` | string | Per message | `"a1b2c3d4e5f6"` |
| `message_id` | string | Per message | `"abc-123-def-456"` |
| `receive_count` | int | Per message | `1` (first attempt), `3` (third retry) |
| `body_length` | int | Per message | `42` |
| `duration_ms` | float | After processing | `150.3` |

### Sample Log Line
```json
{
  "asctime": "2026-09-19T20:00:00",
  "name": "keda-demo",
  "levelname": "INFO",
  "message": "Processing message",
  "pod_name": "keda-demo-7f8b9c-x4k2p",
  "node_name": "ip-10-0-1-100.ec2.internal",
  "namespace": "keda-demo",
  "trace_id": "a1b2c3d4e5f6",
  "message_id": "abc-123-def-456",
  "receive_count": 1,
  "body_length": 42
}
```

---

## Kubernetes Downward API Configuration

To inject pod metadata into environment variables, add this to the
Deployment spec (already included in our Helm chart and Kustomize base):

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
```

---

## Querying Logs

### Local: kubectl

```bash
# All logs from all consumer pods
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=50

# Follow logs in real-time (live demo)
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo -f

# Logs from a specific pod
kubectl logs -n keda-demo keda-demo-7f8b9c-x4k2p

# Parse JSON with jq: filter errors only
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo \
  | jq -r 'select(.levelname == "ERROR")'

# Find all logs for a specific trace_id
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo \
  | jq -r 'select(.trace_id == "a1b2c3d4e5f6")'

# Show only message_id and duration_ms for performance analysis
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo \
  | jq -r '{message_id, duration_ms, pod_name}'

# Count errors per pod
kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo \
  | jq -r 'select(.levelname == "ERROR") | .pod_name' | sort | uniq -c
```

### AWS CloudWatch Logs Insights

```sql
-- Find errors in the last hour
fields @timestamp, message, message_id, pod_name
| filter levelname = "ERROR"
| sort @timestamp desc
| limit 50

-- Trace a specific message across all pods
fields @timestamp, message, pod_name, duration_ms
| filter trace_id = "a1b2c3d4e5f6"
| sort @timestamp asc

-- P99 processing time per pod (last 15 minutes)
fields pod_name, duration_ms
| filter message = "Message processed successfully"
| stats percentile(duration_ms, 99) as p99 by pod_name

-- Messages processed per minute per pod
fields pod_name
| filter message = "Message processed successfully"
| stats count() as msgs_per_min by bin(1m), pod_name

-- Find messages that were retried (receive_count > 1)
fields @timestamp, message_id, receive_count, pod_name
| filter receive_count > 1
| sort receive_count desc
```

---

## Fluent Bit Pipeline

### Installation (Local)
```bash
# Apply the Fluent Bit DaemonSet directly
kubectl apply -f monitoring/fluentbit-config.yaml

# Or install via Helm (production)
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit \
  --namespace monitoring --create-namespace \
  -f monitoring/fluentbit-config.yaml
```

### Pipeline Stages
1. **Input (tail):** Tails `/var/log/containers/keda-demo*.log`
   - Only collects keda-demo pod logs (not system pods)
   - Tracks file position in DB across restarts
   - 5MB memory buffer per file (prevents OOM)

2. **Filter (parser):** Extracts inner JSON from container runtime wrapper
   - Container runtime: `{"log": "{...}", "stream": "stdout", "time": "..."}`
   - After parsing: `{...}` (clean application JSON)

3. **Filter (kubernetes):** Enriches with pod metadata from Kubernetes API
   - Adds: pod_name, namespace, container_name, labels
   - Caches API responses (one query per pod lifecycle)

4. **Filter (modify):** Adds static tags
   - `environment=local` (or `staging`, `prod` per overlay)
   - `application=smartscale-ai`

5. **Output:** Forwards enriched logs to backend
   - Local: stdout (visible via `kubectl logs -n monitoring -l app=fluent-bit`)
   - Production: CloudWatch Logs (uncomment `cloudwatch_logs` output)

### Health Check
```bash
# Check Fluent Bit is running
kubectl get pods -n monitoring -l app=fluent-bit

# Check Fluent Bit's own metrics
kubectl port-forward -n monitoring ds/fluent-bit 2020:2020 &
curl http://localhost:2020/api/v1/health
# Response: {"status":"ok"}
```

---

## Fluent Bit vs Alternatives

| Feature | Fluent Bit | Fluentd | Filebeat |
|---|---|---|---|
| **Memory** | ~450KB | ~40MB | ~100MB |
| **Language** | C | Ruby | Go |
| **K8s native** | ✅ DaemonSet | ✅ DaemonSet | ✅ DaemonSet |
| **CloudWatch** | ✅ Plugin | ✅ Plugin | ❌ (Elastic only) |
| **JSON parsing** | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| **Best for** | Low-resource K8s | Complex routing | Elastic stack |

We chose Fluent Bit for its minimal footprint (10m CPU / 32Mi memory) which
is important when running on free-tier `t3.micro` nodes with limited resources.
