# ⚡ SmartScale AI — Intelligent Event-Driven Autoscaling on AWS

> **An AI-enhanced Kubernetes autoscaling system that predicts SQS queue depth
> and pre-warms consumer pods before traffic spikes arrive — eliminating the
> 40-second cold-start lag of reactive scaling.**

[![CI](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/ci.yml/badge.svg)](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/ci.yml)
[![CD](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/deploy.yml/badge.svg)](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/deploy.yml)
[![Python](https://img.shields.io/badge/Python-3.10%20|%203.11%20|%203.12-3776AB?logo=python&logoColor=white)](application/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29-326CE5?logo=kubernetes&logoColor=white)](manifests/)
[![KEDA](https://img.shields.io/badge/KEDA-2.14-purple?logo=kubernetes&logoColor=white)](manifests/keda-scaled-object.yaml)
[![AWS](https://img.shields.io/badge/AWS-EKS%20·%20SQS%20·%20ECR-FF9900?logo=amazonaws)](terraform/)
[![Terraform](https://img.shields.io/badge/Terraform-1.6+-7B42BC?logo=terraform&logoColor=white)](terraform/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## What This Project Does

SmartScale AI is an **AWS-native, production-grade event-driven autoscaling system** built on Amazon EKS. It goes beyond the standard KEDA SQS trigger by adding a **scikit-learn predictive scaling layer** that forecasts queue depth 5 minutes ahead, allowing Kubernetes to pre-warm consumer pods before traffic arrives.

**The problem with reactive scaling:**
```
t=0    Traffic spike: 25 messages arrive in SQS
t=15   KEDA detects queue depth on next poll (pollingInterval=15s)
t=40   Pods become Ready (scheduling + startupProbe = 25s more)
       ↑ 40 seconds of unprocessed message backlog
```

**The SmartScale AI solution:**
```
t=-5min  Predictor forecasts: "depth will be 25 in 5 minutes"
t=-5min  KEDA External Scaler pre-warms 5 pods
t=0      Traffic spike arrives → pods ALREADY RUNNING → 0s lag
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    PRODUCER LAYER                               │
│  Microservices  /  IoT Devices  /  load-test.sh                │
└────────────────────────┬────────────────────────────────────────┘
                         │ HTTPS / SQS API
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              EVENT LAYER  (Amazon SQS)                          │
│  ┌─────────────────────┐      ┌──────────────────────┐         │
│  │  keda-demo-queue    │─────▶│  Dead Letter Queue   │         │
│  │  (Visibility: 30s)  │ ×3   │  (after 3 failures)  │         │
│  └─────────────────────┘      └──────────────────────┘         │
└────────────────────────┬────────────────────────────────────────┘
          poll every 15s │                    predict 5min ahead
          ┌──────────────┘                         │
          ▼                                         ▼
┌───────────────────┐              ┌────────────────────────────┐
│   KEDA Operator   │◀─GetMetrics─│  AI Predictor              │
│   (ScaledObject)  │             │  (External Scaler, gRPC)    │
│   HPA target:     │             │  LinearRegression model     │
│   0 – 5 replicas  │             │  confidence-based fallback  │
└─────────┬─────────┘              └────────────────────────────┘
          │ scale
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                 AMAZON EKS CLUSTER                              │
│  ┌──────────────────┐     ┌───────────────────────────────┐    │
│  │  On-Demand Node  │     │  Spot Instance Fleet          │    │
│  │  (System pods,   │     │  t3.small/t3a.small/m5.large  │    │
│  │   KEDA operator) │     │  Consumer pods  [0 → 5]       │    │
│  └──────────────────┘     │  ┌─────┐ ┌─────┐ ┌─────┐    │    │
│                            │  │ Pod │ │ Pod │ │ Pod │    │    │
│                            │  │app.py│ │app.py│ │app.py│  │    │
│                            │  └──┬──┘ └──┬──┘ └──┬──┘    │    │
│                            └─────┼────────┼────────┼───────┘    │
└──────────────────────────────────┼────────┼────────┼────────────┘
              SQS delete_message() │        │        │
              :8080/metrics scrape ▼        ▼        ▼
┌─────────────────────────────────────────────────────────────────┐
│              OBSERVABILITY  (kube-prometheus-stack)             │
│  Prometheus ── histogram_quantile(P99) ──▶ Grafana Dashboards   │
│  Alertmanager ── KedaDemoSlowProcessing / HighFailureRate ──▶ 📧│
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Features

| Feature | Details |
|---|---|
| **Scale to zero** | 0 pods when queue empty (KEDA minReplicaCount=0) |
| **AI Predictive Scaling** | Scikit-learn Linear Regression predicts queue depth 5min ahead |
| **Spot Instance fleet** | 5 instance types, 70–90% cost savings vs On-Demand |
| **IRSA authentication** | Zero static AWS credentials — OIDC token exchange only |
| **Prometheus metrics** | 5 custom metrics: processed, failed, duration (P99), active, SQS errors |
| **Alerting** | 7 PrometheusRule alerts: processing stall, DLQ depth, KEDA errors |
| **Graceful shutdown** | SIGTERM → finish in-flight message → delete /tmp/healthy → exit (40s) |
| **Multi-environment** | Dev/Staging/Prod via Kustomize overlays + Helm values-*.yaml |
| **Helm chart** | 10 conditional templates, 3 required values, `--atomic` CI/CD |
| **Security** | PSS restricted, NetworkPolicy, RBAC (resourceNames-scoped), Secrets Manager stub |
| **Chaos testing** | 5 experiments: pod-kill, scale-to-zero, network-partition, flood, spot-drain |
| **CI matrix** | pytest on Python 3.10 / 3.11 / 3.12, chaos dry-run, Helm lint, Terraform validate |

---

## Quick Start

### Prerequisites

```bash
git clone https://github.com/Harshads-git/aws-keda-eks-autoscaling.git
cd aws-keda-eks-autoscaling

# Tools required: aws-cli >= 2.13, terraform >= 1.6, kubectl >= 1.28, helm >= 3.12
```

### 1. Provision AWS Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # Fill in your values
terraform init
terraform plan
terraform apply

# Outputs you'll need:
terraform output sqs_queue_url
terraform output consumer_role_arn
terraform output ecr_repository_url
```

### 2. Build and Push the Consumer Image

```bash
export ECR_URI=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_URI"
docker build -t "$ECR_URI:latest" application/
docker push "$ECR_URI:latest"
```

### 3. Deploy to Kubernetes

```bash
# Option A: Kustomize (simple)
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl apply -k kustomize/overlays/dev/

# Option B: Helm (recommended for prod)
export QUEUE_URL=$(terraform output -raw sqs_queue_url)
export CONSUMER_ROLE_ARN=$(terraform output -raw consumer_role_arn)
helm upgrade --install keda-demo ./helm/keda-demo \
  --set image.repository="$ECR_URI" \
  --set image.tag=latest \
  --set aws.sqsQueueUrl="$QUEUE_URL" \
  --set aws.irsaRoleArn="$CONSUMER_ROLE_ARN" \
  --atomic --timeout 5m

# Option C: deploy wrapper script
bash scripts/deploy-environment.sh dev
```

### 4. Test the Autoscaling

```bash
export QUEUE_URL=$(terraform output -raw sqs_queue_url)

# Send 25 messages and watch KEDA scale 0 → 5 pods
bash scripts/load-test.sh --scenario burst --count 25

# Watch pods in real time (another terminal)
watch -n 3 kubectl get pods -n keda-demo
```

### 5. Run Tests Locally (No AWS Needed)

```bash
pip install -r application/requirements.txt -r application/requirements-dev.txt

# Unit tests (moto mocks SQS)
pytest application/test_app.py -v

# Chaos / resilience tests
pytest application/chaos_test.py -v

# Performance micro-benchmarks
pytest application/performance_test.py -v -s

# AI predictor demo
python ai/predictor.py
```

---

## Project Structure

```
aws-keda-eks-autoscaling/
│
├── application/               # Python SQS consumer
│   ├── app.py                 # Main consumer with SIGTERM handler + Prometheus metrics
│   ├── test_app.py            # Unit tests (moto — no AWS account needed)
│   ├── chaos_test.py          # Resilience tests (SIGTERM, error handling, health file)
│   └── performance_test.py    # P99 latency micro-benchmarks
│
├── ai/                        # Predictive scaling AI prototype
│   ├── predictor.py           # Scikit-learn LinearRegression queue depth predictor
│   ├── keda_external_scaler_stub.py  # KEDA gRPC External Scaler integration
│   └── test_predictor.py      # AI model unit tests
│
├── terraform/                 # All AWS infrastructure as IaC
│   └── modules/               # vpc · eks · sqs · irsa · monitoring
│
├── manifests/                 # Raw Kubernetes YAML (13 files)
├── helm/keda-demo/            # Helm chart (10 templates, values-{staging,prod}.yaml)
├── kustomize/                 # Kustomize overlays: dev · staging · prod
│
├── scripts/                   # Operational scripts
│   ├── load-test.sh           # Burst/ramp/wave load scenarios + scale-up timing
│   ├── benchmark.sh           # Prometheus P50/P95/P99 latency queries + SLO gates
│   ├── chaos-test.sh          # 5 chaos experiments: pod-kill, flood, spot-drain, …
│   ├── deploy-environment.sh  # Multi-env deploy wrapper (Kustomize or Helm)
│   ├── deploy-all-manifests.sh # 7-step ordered manifest deploy
│   └── cleanup.sh             # Safe AWS resource teardown in dependency order
│
└── docs/                      # 13 guides
    ├── architecture.md        # IRSA trust chain, KEDA math, VPC design
    ├── helm-guide.md          # Chart usage, rollback, dry-run
    ├── security-guide.md      # 5-layer security model, RBAC, PSS
    ├── observability-guide.md # PromQL queries, alert runbook
    ├── chaos-engineering-guide.md  # Hypothesis model, GameDay runbook
    ├── ai-scaling-guide.md    # Predictive vs reactive, model roadmap
    ├── performance-guide.md   # SLOs, scale-up budget, tuning knobs
    └── contributing.md        # Dev setup, commit conventions, architecture rules
```

---

## SLOs at a Glance

| Metric | Target | Measures |
|---|---|---|
| Scale-up lag (burst) | ≤ 45s | Time from spike to pods Ready |
| P99 processing latency | ≤ 5s | Slowest 1% of messages |
| Error rate | < 1% | Failed / total messages |
| Pod recovery (kill) | ≤ 90s | KEDA reschedule after pod delete |
| Scale-to-zero | ≤ 360s | Pods gone after queue empties |

---

## Comparison to GCP Reference

This project is the AWS equivalent of [gcp-keda-gke-event-driven-autoscaling-demo](https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo), with additional innovations:

| Capability | GCP Reference | SmartScale AI (This Project) |
|---|---|---|
| Queue-based autoscaling | ✅ Pub/Sub + KEDA | ✅ SQS + KEDA |
| Scale to zero | ✅ | ✅ |
| AI Predictive Scaling | ❌ | ✅ (scikit-learn External Scaler) |
| Spot instance fleet | ❌ | ✅ (5 instance types, NTH) |
| Chaos engineering suite | ❌ | ✅ (5 experiments + GameDay runbook) |
| Multi-environment Kustomize | ❌ | ✅ (dev/staging/prod overlays) |
| Prometheus + Alerting | ❌ | ✅ (7 alert rules, Grafana) |

---

## Contributing

See [`docs/contributing.md`](docs/contributing.md) for:
- Local dev setup and prerequisites
- How to run all test suites
- Commit message convention (Conventional Commits enforced by CI)
- Architecture rules that must not be broken

---

## License

MIT — see [LICENSE](LICENSE)
