# ⚡ SmartScale AI — Intelligent Event-Driven Autoscaling Platform on AWS

> **An enterprise-grade, AI-assisted Kubernetes autoscaling platform on Amazon EKS that forecasts SQS queue depth, pre-warms consumer pods before traffic arrives, scales to zero when idle, and enforces full-stack DevSecOps and GitOps.**

[![50-Day Capstone](https://img.shields.io/badge/Milestone-50%20Days%20Complete-gold?style=for-the-badge&logo=target)](docs/capstone-showcase.md)
[![Total Commits](https://img.shields.io/badge/Commits-165+-blue?style=for-the-badge&logo=git)](docs/project-retrospective.md)

[![CI](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/ci.yml/badge.svg)](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/ci.yml)
[![Security Scan](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/security-scan.yml/badge.svg)](docs/security-guide.md)
[![SBOM Audit](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/sbom.yml/badge.svg)](docs/sbom-guide.md)
[![Python](https://img.shields.io/badge/Python-3.10%20|%203.11%20|%203.12-3776AB?logo=python&logoColor=white)](application/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29-326CE5?logo=kubernetes&logoColor=white)](manifests/)
[![KEDA](https://img.shields.io/badge/KEDA-2.14-purple?logo=kubernetes&logoColor=white)](manifests/keda-scaled-object.yaml)
[![AWS](https://img.shields.io/badge/AWS-EKS%20·%20SQS%20·%20ECR-FF9900?logo=amazonaws)](terraform/)
[![Terraform](https://img.shields.io/badge/Terraform-1.6+-7B42BC?logo=terraform&logoColor=white)](terraform/)
[![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-orange?logo=argo)](gitops/)
[![DevSecOps](https://img.shields.io/badge/Security-OPA%20·%20Falco%20·%20Trivy-green)](policies/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 📖 Executive Overview

SmartScale AI solves the fundamental flaw of reactive Kubernetes autoscaling: **pod startup lag**.

### The Problem: Reactive Cold-Start Delay
In conventional event-driven systems using standard HPA or raw KEDA:
```text
t=0s    Burst traffic spike arrives in Amazon SQS (e.g. 50 messages)
t=15s   KEDA polls SQS queue depth and calculates required replicas
t=40s   Pods become Ready (scheduling + image pull + startup probes take 25s)
        ↑ 40 SECONDS OF UNPROCESSED BACKLOG SPIKING P99 QUEUE LATENCY
```

### The Solution: SmartScale AI Proactive Pre-Warming
SmartScale AI combines an **ARIMA(1,1,1) time-series forecasting model** with automated confidence-gated safety fallbacks:
```text
t=-60s  Predictor forecasts incoming surge based on queue momentum
t=-45s  KEDA External Scaler pre-warms consumer pods in advance
t=0s    Traffic burst arrives → Pods are ALREADY RUNNING → 0-second queue lag
```

---

## 🏛️ End-to-End System Architecture

```text
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

## 🔌 Microservice & Network Port Matrix

| Service | File | Port | Purpose |
|---|---|---|---|
| **Core Consumer** | [`application/app.py`](application/app.py) | `8080` | Primary SQS consumer worker with Prometheus metrics & SIGTERM handling |
| **DLQ Processor** | [`application/dlq_processor.py`](application/dlq_processor.py) | `8081` | Dead-letter queue re-drive and poison pill quarantine |
| **Prediction API** | [`application/prediction_api.py`](application/prediction_api.py) | `8090` | ARIMA(1,1,1) time-series forecasting & confidence-gated scaler |
| **Producer REST API** | [`application/producer_api.py`](application/producer_api.py) | `8091` | High-throughput SQS message generator (`/send`, `/send/bulk`, `/queue/depth`) |
| **Live Web Dashboard** | [`application/dashboard.py`](application/dashboard.py) | `8092` | Server-rendered real-time HTML dashboard with 3s HTMX partial swapping |

---

## 🌟 Key Capabilities by Phase

### Phase 1: Observability & Tracing (Days 31–35)
* **Prometheus & Grafana:** Custom dashboards tracking consumer throughput, failure rates, and P99 latency.
* **Alertmanager & SLOs:** Multi-window, multi-burn-rate alerting rules protecting message latency budgets.
* **Logging & Tracing:** Fluent Bit structured JSON streaming and OpenTelemetry distributed trace context propagation.

### Phase 2: Advanced AI & Multi-Queue (Days 36–40)
* **ARIMA(1,1,1) Forecasting:** Time-series demand forecasting handling trend momentum and mean-reverting queue bursts.
* **Walk-Forward Model Validation:** Automated evaluator calculating MAPE against sliding test windows before activating models.
* **Dual-Queue Routing:** Multi-queue consumer prioritizing urgent messages while processing background batch work.

### Phase 3: DevSecOps, Policy as Code & GitOps (Days 41–45)
* **Container & IaC Scanning:** Trivy auditing vulnerability CVEs in GitHub Actions CI pipelines.
* **Admission Control:** OPA Gatekeeper constraint templates enforcing CPU/memory limits and non-root execution.
* **Runtime Defense:** Falco eBPF syscall monitoring with custom MITRE ATT&CK security rules.
* **GitOps Continuous Delivery:** ArgoCD declarative deployment with `ignoreDifferences` on autoscaled replicas and automated self-healing.
* **Supply Chain Security:** Syft/Grype automated Software Bill of Materials (SBOM) and GPL license compliance enforcement.

### Phase 4: Full-Stack Capstone (Days 46–50)
* **Producer API:** REST interface with 10-message batch chunking for load testing and demo orchestration.
* **HTMX Web Dashboard:** Zero-build, single-container live operations UI with automated 3s DOM swapping.
* **Pytest E2E Test Suite:** Complete integration harness testing health, predictions, queue lifecycle, and closed-loop scaling.
* **Architecture Governance:** Formal Architecture Decision Records (ADRs 0001, 0002, 0003).

---

## 🚀 Quick Start Guide

### Option 1: 5-Minute Local Demo (Zero AWS Cost)

Run the full platform locally using Docker Desktop, Kind, and ElasticMQ:

```bash
# 1. Clone repository
git clone https://github.com/Harshads-git/aws-keda-eks-autoscaling.git
cd aws-keda-eks-autoscaling

# 2. Deploy local manifests to Kind cluster
kubectl apply -f manifests/

# 3. Port-forward the Live Dashboard and Producer API
kubectl port-forward -n keda-demo svc/dashboard 8092:8092 &
kubectl port-forward -n keda-demo svc/producer-api 8091:8091 &

# 4. Open Dashboard in Browser
# http://localhost:8092

# 5. Inject a burst of 30 messages to trigger autoscaling
curl -X POST http://localhost:8091/send/bulk \
  -H "Content-Type: application/json" \
  -d '{"count": 30, "queue_type": "priority"}'

# 6. Watch pods scale from 1 to 8/10 replicas on the dashboard!
```

### Option 2: Deploy to Real AWS EKS

```bash
# 1. Provision Infrastructure via Terraform
cd terraform
terraform init
terraform apply

# 2. Deploy via ArgoCD GitOps
kubectl apply -f gitops/argocd-project.yaml
kubectl apply -f gitops/argocd-application.yaml

# 3. Monitor sync and autoscaling
argocd app get smartscale-ai
```

---

## 🧪 Testing Suites

```bash
# Install dependencies
pip install -r application/requirements.txt pytest moto

# 1. Unit Tests (Consumer, DLQ, Predictor)
pytest application/test_app.py application/test_producer_api.py -v

# 2. AI Model Walk-Forward & Backtesting Tests
pytest ai/test_predictor.py -v

# 3. Chaos Engineering & Resilience Tests
pytest application/chaos_test.py -v

# 4. Full End-to-End Integration Tests
pytest tests/e2e/ -v
```

---

## 📚 Documentation Index

| Guide | Description |
|---|---|
| [**Capstone Portfolio Showcase**](docs/capstone-showcase.md) | Executive presentation, cost analysis, benchmarks, and portfolio summary |
| [**50-Day Engineering Retrospective**](docs/project-retrospective.md) | Architectural evolution, challenges solved, quantitative metrics, lessons learned |
| [**Architecture Decision Records (ADRs)**](docs/adr/README.md) | Master ADR index: KEDA (0001), ARIMA (0002), HTMX Dashboard (0003) |
| [**End-to-End Testing Guide**](docs/e2e-testing-guide.md) | Pytest E2E architecture, local/Kind/CI execution, and troubleshooting |
| [**Live Web Dashboard Guide**](docs/dashboard-guide.md) | HTMX partial update architecture, layout guide, and customization |
| [**Producer REST API Guide**](docs/producer-api-guide.md) | Batch SQS message generation, API schema reference, and load testing |
| [**GitOps with ArgoCD Guide**](docs/gitops-guide.md) | Declarative sync, self-healing, and KEDA ignoreDifferences configuration |
| [**Supply Chain & SBOM Policy Guide**](docs/sbom-guide.md) | Syft SBOM generation, Grype vulnerability gating, and license compliance |
| [**Runtime Security with Falco Guide**](docs/falco-guide.md) | eBPF kernel syscall monitoring and custom MITRE ATT&CK detection rules |
| [**Policy as Code with OPA Gatekeeper**](docs/policy-guide.md) | Admission control constraint templates enforcing non-root and resource limits |
| [**Trivy Security Scanning Guide**](docs/security-guide.md) | Automated CVE vulnerability scanning across containers and Terraform IaC |

---

## ⚖️ License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for details.
