# SmartScale AI — Capstone Portfolio Showcase & Technical Brief

> **Intelligent, Event-Driven, AI-Assisted Autoscaling Platform on AWS & Kubernetes**  
> *A 50-day engineering capstone combining Kubernetes, Machine Learning, DevSecOps, and GitOps.*

---

## 1. Executive Summary

**SmartScale AI** is an enterprise-ready event-driven autoscaling system built for asynchronous, queue-based distributed systems.

Traditional Kubernetes Horizontal Pod Autoscaling (HPA) relies on lagging resource metrics (CPU/Memory) and cannot scale workloads to zero. KEDA solves reactive scaling to zero, but still suffers from a **15–30 second pod startup latency** during sudden arrival spikes.

SmartScale AI bridges this gap through a **hybrid AI predictive autoscaling pipeline**:
1. Uses an **ARIMA(1,1,1) time-series model** to forecast queue backlog depth ahead of arrival spikes.
2. Pre-warms consumer pods before queue depth accumulates, eliminating cold-start delays.
3. Automatically falls back to reactive ceiling logic if model confidence drops below 50%.
4. Operates with defense-in-depth security: OPA Gatekeeper policies, Falco runtime syscall defense, Trivy CVE scanning, and Syft/Grype SBOM auditing.
5. Reconciles declaratively using ArgoCD GitOps with automated drift self-healing.
6. Provides an interactive, zero-build HTMX dashboard and REST producer API for live demonstrations.

---

## 2. End-to-End System Architecture

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                               OPERATOR & CLIENT LAYER                                  │
│   Web Browser (Dashboard :8092)   │   REST Client (Producer :8091)   │   Pytest E2E    │
└──────────────────┬────────────────┴──────────────────┬───────────────┴────────┬────────┘
                   │ HTTP / HTMX                       │ POST /send/bulk        │
                   ▼                                   ▼                        │
┌───────────────────────────────────────────────────────────────────────┐       │
│                       MICROSERVICES APPLICATION LAYER                 │       │
│                                                                       │       │
│  ┌─────────────────────────┐               ┌────────────────────────┐ │       │
│  │   Live Web Dashboard    │               │  Message Producer API  │ │       │
│  │       (Port 8092)       │               │      (Port 8091)       │ │       │
│  │   FastAPI + HTMX Poller │               │  FastAPI + Batch SQS   │ │       │
│  └────────────┬────────────┘               └───────────┬────────────┘ │       │
│               │                                        │              │       │
│               │ Proxies / Reads                        │ SQS Batch    │       │
│               ▼                                        ▼              │       │
│  ┌─────────────────────────┐               ┌────────────────────────┐ │       │
│  │     Prediction API      │               │     AWS SQS Queues     │ │       │
│  │       (Port 8090)       │◀─Reads Depth──│  • Priority Queue      │ │       │
│  │  ARIMA(1,1,1) Forecast  │               │  • Batch Queue         │ │       │
│  │  Confidence Fallback    │               │  • Dead Letter Queue   │ │       │
│  └────────────┬────────────┘               └───────────┬────────────┘ │       │
│               │ Recommendations                        │              │       │
│               ▼                                        ▼              │       │
│  ┌──────────────────────────────────────────────────────────────────┐ │       │
│  │                    KEDA AUTOSCALER & KUBERNETES                  │ │       │
│  │  • KEDA Operator (Polls SQS & Queries Prediction API via gRPC)   │ │       │
│  │  • Horizontal Pod Autoscaler (HPA manages 0 → 10 replicas)       │ │       │
│  └──────────────────────────────────┬───────────────────────────────┘ │       │
│                                     │ Scale Events                    │       │
│                                     ▼                                 │       │
│  ┌──────────────────────────────────────────────────────────────────┐ │       │
│  │                      CONSUMER WORKER FLEET                       │ │       │
│  │  • Multi-Queue Consumer (Port 8080) — Prioritizes urgent events  │ │       │
│  │  • DLQ Processor Pod    (Port 8081) — Isolates poison messages   │ │       │
│  └──────────────────────────────────────────────────────────────────┘ │       │
└───────────────────────────────────────────────────────────────────────┼───────┘
                                                                        │
┌───────────────────────────────────────────────────────────────────────┴────────┐
│                        DEVSECOPS, GITOPS & OBSERVABILITY                       │
│  ┌───────────────────────┐ ┌──────────────────────┐ ┌────────────────────────┐ │
│  │  ArgoCD GitOps Sync   │ │  OPA Gatekeeper      │ │  Falco eBPF Runtime    │ │
│  │  ignoreDifferences    │ │  Resource limits &   │ │  Syscall monitoring    │ │
│  │  Self-healing drift   │ │  Non-root enforcement│ │  MITRE ATT&CK rules    │ │
│  └───────────────────────┘ └──────────────────────┘ └────────────────────────┘ │
│  ┌───────────────────────┐ ┌──────────────────────┐ ┌────────────────────────┐ │
│  │  Prometheus & Grafana │ │  OpenTelemetry OTel  │ │  Syft / Grype SBOM     │ │
│  │  SLO multi-burn-rates │ │  Trace propagation   │ │  License compliance    │ │
│  └───────────────────────┘ └──────────────────────┘ └────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Microservice & Network Port Matrix

| Service | Script / Component | Port | Purpose |
|---|---|---|---|
| **Core Consumer** | `application/app.py` | `8080` | SQS message consumer worker with Prometheus metrics |
| **DLQ Processor** | `application/dlq_processor.py` | `8081` | Dead-letter queue re-drive and poison pill quarantine |
| **Prediction API** | `application/prediction_api.py` | `8090` | ARIMA time-series model serving & scaling recommendations |
| **Producer API** | `application/producer_api.py` | `8091` | REST interface for single and bulk SQS message generation |
| **Live Dashboard** | `application/dashboard.py` | `8092` | Real-time HTML dashboard with 3s HTMX partial swapping |

---

## 4. Key Architectural Capabilities

### 1. Zero-Cost Idle & Rapid Scale-Out
* Scales worker pods down to **0 replicas** during inactivity, releasing all EC2/compute allocation.
* Reactively provisions worker pods from 0 to 1 upon the first SQS message arrival.
* Auto-scales horizontally up to 10 pods during heavy bursts based on queue backlog depth.

### 2. Proactive AI Prediction Layer
* Features **ARIMA(1,1,1)** time-series forecasting to anticipate demand spikes 1–3 minutes in advance.
* Automated **walk-forward backtesting** (`ai/model_evaluator.py`) continuously tracks Mean Absolute Percentage Error (MAPE).
* **Confidence-gated safety guard**: If statistical confidence drops below `0.50`, the system automatically reverts to standard deterministic reactive scaling without service interruption.

### 3. Production DevSecOps & Governance
* **Static Analysis:** Trivy vulnerability scanner runs in GitHub Actions CI across container images and Terraform IaC.
* **Admission Control:** OPA Gatekeeper policies enforce container resource limits and non-root execution.
* **Runtime Defense:** Falco monitors kernel syscalls via eBPF for unauthorized shell spawns, sensitive directory access, and binary execution.
* **Supply Chain Security:** Automated Syft SBOM generation with Grype vulnerability auditing and prohibited software license enforcement.

### 4. GitOps Continuous Delivery
* Declarative deployment state managed via ArgoCD.
* Employs `ignoreDifferences` on `/spec/replicas` to prevent KEDA autoscaling decisions from conflicting with GitOps reconcilers.
* Automated self-healing remediates out-of-band manual drift within 3 minutes.

---

## 5. Cost Analysis & Financial Impact

| Deployment Tier | Infrastructure Scope | Monthly Estimate | Cost Efficiency Features |
|---|---|---|---|
| **Local Sandbox** | Docker Desktop + Kind + ElasticMQ | **$0.00** | 100% free local simulation of AWS EKS and SQS |
| **AWS Free Tier** | t3.small Spot Instances + SQS Free Tier | **< $5.00** | Uses SQS 1M free requests/mo; 15s polling interval |
| **Enterprise Production** | Multi-AZ EKS + Spot Fleet + SQS | **~$95 / mo** *(vs $240 standard)* | **~60% overall savings** via Spot instances and Scale-to-Zero |

---

## 6. 5-Minute Demonstration Walkthrough

Follow these steps to demonstrate the full end-to-end capabilities:

```bash
# 1. Start Port-Forwarding (in separate background sessions)
kubectl port-forward -n keda-demo svc/dashboard 8092:8092 &
kubectl port-forward -n keda-demo svc/producer-api 8091:8091 &
kubectl port-forward -n keda-demo svc/prediction-api 8090:8090 &

# 2. Open Live Web Dashboard in Browser
# URL: http://localhost:8092 (Notice green status cards: 0 messages, 1 pod)

# 3. Inject Load via Producer API or Dashboard UI
curl -X POST http://localhost:8091/send/bulk \
  -H "Content-Type: application/json" \
  -d '{"count": 30, "queue_type": "priority"}'

# 4. Observe Immediate Reaction on Dashboard
# - Priority Queue Card turns Red (30 messages)
# - AI Predictor forecasts workload surge
# - Consumer Pods scale up from 1 to 8/10 pods within seconds

# 5. Run Automated Pytest End-to-End Verification
pytest tests/e2e/ -v
```

---

## 7. Technical Competencies Demonstrated

* **Cloud & Infrastructure as Code:** AWS EKS, SQS, IAM, IRSA, VPC, Terraform (Modules, State, Variables).
* **Kubernetes & Cloud Native:** KEDA, HPA, Custom Metrics, RBAC, Services, ConfigMaps, Secrets, Kustomize.
* **Applied AI & MLOps:** Time-Series Forecasting (ARIMA), Scikit-Learn, Walk-Forward Validation, Model Registries.
* **DevSecOps & Platform Engineering:** Trivy, OPA Gatekeeper, Falco eBPF, Syft/Grype SBOM, SLSA compliance.
* **GitOps & CI/CD:** ArgoCD, Declarative Sync, GitHub Actions multi-stage CI workflows.
* **Software Architecture:** Python, FastAPI, HTMX, Asynchronous Boto3 Batching, Prometheus Telemetry, OpenTelemetry.
