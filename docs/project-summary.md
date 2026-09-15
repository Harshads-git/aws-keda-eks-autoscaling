# SmartScale AI — Project Summary

**An intelligent, event-driven autoscaling framework on AWS that combines
KEDA (Kubernetes Event-Driven Autoscaling) with a scikit-learn predictive
model to eliminate cold-start latency in SQS-driven workloads.**

---

## Problem Solved

Reactive autoscaling (KEDA's default SQS trigger) introduces a **40-second
lag** between a traffic spike and consumer pods being ready:
- KEDA polls SQS every 15 seconds (up to 15s detection delay)
- Kubernetes takes 5–25 seconds to schedule and start pods
- startupProbe adds 5 seconds minimum before traffic is served

For high-throughput message queues, this means thousands of messages
accumulate before processing begins. **SmartScale AI predicts the spike
5 minutes ahead and pre-warms pods, reducing lag to near zero.**

---

## Architecture

```
Producer → SQS (main + DLQ) → KEDA Operator ← AI External Scaler
                                    ↓
                         EKS Consumer Pods (0–5, Spot)
                                    ↓
                         Prometheus + Grafana + Alertmanager
```

**5 Layers:** Producer → Event (SQS) → Intelligent Scaling (KEDA + AI Predictor)
→ Compute (EKS Spot fleet) → Observability (kube-prometheus-stack)

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Queue → autoscaling bridge | KEDA 2.14 | Supports scale-to-zero; HPA cannot go below 1 replica |
| AWS auth in Kubernetes | IRSA (OIDC) | Zero static credentials; 1-hour rotating tokens via STS |
| AI model | Linear Regression (scikit-learn) | Works with 10–50 observations; LSTM requires 1,000+ |
| Cost optimization | Spot instances (5 types) | 70–90% cheaper; NTH handles 2-min interruption warning |
| Message safety | SQS visibility timeout + delete-on-success | At-least-once delivery; failed messages auto-redeliver |
| Config management | Kustomize overlays (dev/staging/prod) | Single base YAML, environment patches — no duplication |
| Chart packaging | Helm (10 templates, 3 required values) | Parameterized deploy; `--atomic` enables CI/CD rollback |
| Security | PSS restricted + NetworkPolicy + RBAC (resourceNames) | Least-privilege at namespace, pod, and API level |

---

## Metrics and SLOs

| SLO | Target | How Measured |
|---|---|---|
| Scale-up lag | ≤ 45s | `scripts/load-test.sh` (burst scenario) |
| P99 processing latency | ≤ 5s | `histogram_quantile(0.99, ...)` via `scripts/benchmark.sh` |
| Error rate | < 1% | `rate(keda_demo_messages_failed_total[5m])` |
| Pod kill recovery | ≤ 90s | `scripts/chaos-test.sh --experiment pod-kill` |
| Scale-to-zero | ≤ 360s | `scripts/chaos-test.sh --experiment scale-to-zero` |

5 custom Prometheus metrics (Counter, Gauge, Histogram) + 7 PrometheusRule alerts.

---

## What Differentiates This Project

1. **AI Predictive Scaling** (`ai/predictor.py`) — No equivalent in the GCP reference implementation. Linear Regression on 7 rolling window features (lag, mean, std, velocity, acceleration) predicts queue depth 5 minutes ahead. Plugs into KEDA via the External Scaler gRPC protocol.

2. **Chaos Engineering Suite** (`scripts/chaos-test.sh`) — 5 hypothesis-driven experiments (pod kill, scale-to-zero, network partition, queue flood, Spot interruption) with a GameDay runbook. Validates system resilience before production.

3. **Full 3-Environment Promotion Pipeline** — Dev (fast/cheap) → Staging (prod-matching limits) → Prod (minReplicaCount=1 for zero cold-start) via Kustomize overlays AND Helm values-*.yaml files.

4. **Production-Grade Shutdown** (`application/app.py`) — SIGTERM → set `_running=False` → finish in-flight message → `delete_message()` → remove `/tmp/healthy` → exit within `terminationGracePeriodSeconds=40`. Zero message loss on pod eviction.

---

## Repository Statistics

| Metric | Value |
|---|---|
| Total commits | 99 |
| Python application (app.py) | ~400 lines |
| Test suites | 4 (unit, chaos, AI, performance) |
| Kubernetes manifests | 13 |
| Helm templates | 10 |
| Terraform modules | 5 (vpc, eks, sqs, irsa, monitoring) |
| Operational scripts | 9 |
| Documentation guides | 14 |
| CI jobs | 7 (lint, Python ×3, AI, chaos dry-run, docker, terraform, helm) |
| Prometheus alerts | 7 |

---

## Resume Bullet (Copy-Paste Ready)

> **SmartScale AI** — Built a production-grade, AI-enhanced event-driven autoscaling system on AWS EKS using KEDA, Amazon SQS, and Terraform IaC. Implemented a scikit-learn Linear Regression External Scaler that predicts SQS queue depth 5 minutes ahead, reducing scale-up lag from 40s to near-zero. Deployed a full observability stack (Prometheus, Grafana, 7 alert rules), Helm chart with multi-environment Kustomize overlays (dev/staging/prod), chaos engineering suite (5 experiments), and a CI/CD pipeline with Python matrix testing (3.10/3.11/3.12), Helm lint, and Terraform validation.
> **Stack:** Python 3.11 · AWS EKS · KEDA 2.14 · Amazon SQS · Terraform · Helm · Kustomize · Prometheus · GitHub Actions · scikit-learn · Docker · Spot Instances · IRSA

---

## Links

- **Repository:** https://github.com/Harshads-git/aws-keda-eks-autoscaling
- **GCP Reference:** https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo
- **KEDA Docs:** https://keda.sh/docs/2.14/
- **KEDA External Scaler Protocol:** https://keda.sh/docs/2.14/concepts/external-scalers/
