# ⚡ AWS KEDA EKS — Event-Driven Autoscaling

> **Scale Kubernetes workloads to zero and back using Amazon SQS queue depth as the autoscaling trigger.**

![CI](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/ci.yml/badge.svg)
![CD](https://github.com/Harshads-git/aws-keda-eks-autoscaling/actions/workflows/deploy.yml/badge.svg)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29-326CE5?logo=kubernetes&logoColor=white)
![KEDA](https://img.shields.io/badge/KEDA-2.14-purple?logo=kubernetes)
![AWS](https://img.shields.io/badge/AWS-EKS%20%7C%20SQS%20%7C%20ECR-FF9900?logo=amazon-aws)
![Terraform](https://img.shields.io/badge/Terraform-1.7+-7B42BC?logo=terraform)
![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 📌 What This Project Demonstrates

This is an **original AWS portfolio project** that implements event-driven autoscaling on Kubernetes. When messages arrive in an **Amazon SQS queue**, KEDA automatically scales the consumer pods from **0 → N**. When the queue empties, pods scale back **to zero** — eliminating idle compute costs.

### Architecture at a Glance

```
  Message Producer
        │
        ▼
  Amazon SQS ──── queue depth ────▶ KEDA ScaledObject
  (keda-demo-queue)                        │
                                           │ scales
                                           ▼
                                  EKS Deployment (keda-demo)
                                    [0 → 5 pods]
                                           │
                                           │ consumes messages
                                           ▼
                                    Message deleted from SQS
```

> 📄 See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full deep-dive including IRSA, VPC design, and KEDA internals.

---

## 🔁 GCP → AWS Service Mapping

This project is inspired by [gcp-keda-gke-event-driven-autoscaling-demo](https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo) and re-implements the same concept on AWS Free Tier.

| GCP (Reference) | AWS (This Project) |
|---|---|
| GKE | Amazon EKS (t3.micro nodes) |
| Cloud Pub/Sub | Amazon SQS |
| GCR / Artifact Registry | Amazon ECR |
| Workload Identity | IRSA (IAM Roles for Service Accounts) |
| Cloud Monitoring | Amazon CloudWatch |
| gcloud CLI | AWS CLI v2 |

---

## 🏗️ Tech Stack

| Category | Technology |
|---|---|
| **Container Orchestration** | Amazon EKS (Kubernetes 1.29) |
| **Event-Driven Autoscaling** | KEDA 2.14 |
| **Message Queue** | Amazon SQS (Standard Queue + DLQ) |
| **Container Registry** | Amazon ECR |
| **Infrastructure as Code** | Terraform 1.7+ |
| **Application** | Python 3.11 + boto3 |
| **CI/CD** | GitHub Actions (OIDC — zero stored secrets) |
| **Observability** | Amazon CloudWatch + Container Insights |
| **Security** | IRSA, Pod Security Standards, NetworkPolicy, Trivy |

---

## 📋 Prerequisites

Before starting, ensure you have the following installed:

| Tool | Version | Purpose |
|---|---|---|
| `aws` CLI | v2.x | Interact with AWS services |
| `kubectl` | v1.29+ | Manage Kubernetes resources |
| `helm` | v3.x | Deploy KEDA via Helm chart |
| `terraform` | v1.7+ | Provision infrastructure |
| `docker` | v24+ | Build container images |
| `git` | v2.x | Version control |

**AWS Account Requirements:**
- AWS account with IAM admin access (or scoped permissions — see `docs/setup-guide.md`)
- AWS Free Tier recommended (note: EKS control plane is **NOT** Free Tier — ~$0.10/hr)
- AWS CLI configured: `aws configure`

---

## 🚀 Quick Start

> ⚠️ **Full setup takes approximately 30–45 minutes.** See `docs/setup-guide.md` for detailed steps.

### 1. Clone & Configure

```bash
git clone https://github.com/Harshads-git/aws-keda-eks-autoscaling.git
cd aws-keda-eks-autoscaling

# Copy and fill in your AWS environment variables
cp .env.example .env
# Edit .env with your AWS_ACCOUNT_ID, AWS_REGION, etc.
```

### 2. Validate Prerequisites

```bash
bash scripts/check-prerequisites.sh
```

### 3. Provision Infrastructure

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 4. Install KEDA & Deploy Application

```bash
bash scripts/install-keda.sh
bash scripts/deploy-all-manifests.sh
```

### 5. Test Autoscaling

```bash
# Watch pods in real time (split terminal)
bash scripts/watch-scaling.sh

# In another terminal, send 50 messages to SQS
bash scripts/load-test.sh
```

You should see pods scale from **0 → 5**, drain the queue, then scale back to **0**.

---

## 📁 Repository Structure

```
aws-keda-eks-autoscaling/
├── .github/
│   └── workflows/
│       ├── ci.yml              # Build & push Docker image to ECR
│       └── deploy.yml          # Deploy to EKS on push to main
├── application/
│   ├── app.py                  # Python SQS consumer
│   ├── Dockerfile              # Multi-stage container image
│   └── requirements.txt        # Python dependencies (boto3)
├── scripts/
│   ├── check-prerequisites.sh  # Validate local toolchain
│   ├── setup-sqs.sh            # Create SQS queue + DLQ
│   ├── setup-ecr.sh            # Create ECR repository
│   ├── install-keda.sh         # Deploy KEDA via Helm
│   ├── generate-messages.sh    # Send test messages to SQS
│   ├── load-test.sh            # Burst 50 messages for scale-up test
│   ├── watch-scaling.sh        # Observe HPA and pod scaling
│   ├── deploy-all-manifests.sh # One-shot K8s deployment
│   └── cleanup.sh              # Tear down all AWS resources
├── terraform/
│   ├── main.tf                 # Root orchestration
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── backend.tf              # S3 remote state + DynamoDB locking
│   └── modules/
│       ├── vpc/                # VPC + subnets + NAT Gateway
│       ├── eks/                # EKS cluster + managed node group
│       ├── sqs/                # SQS queue + DLQ + IAM policy
│       └── irsa/               # OIDC provider + IAM roles for K8s SA
├── manifests/
│   ├── namespace.yaml
│   ├── serviceaccount.yaml     # IRSA-annotated ServiceAccount
│   ├── configmap.yaml
│   ├── deployment.yaml         # App Deployment
│   ├── keda-trigger-auth.yaml  # TriggerAuthentication (AWS IRSA)
│   └── keda-scaled-object.yaml # ScaledObject (SQS scaler)
├── kustomize/
│   ├── base/                   # Base K8s manifests
│   └── overlays/dev/           # Dev environment overrides
├── docs/
│   ├── setup-guide.md
│   ├── irsa-vs-workload-identity.md
│   ├── keda-sqs-scaler.md
│   ├── troubleshooting.md
│   ├── cost-analysis.md
│   └── day-by-day-log.md
├── ARCHITECTURE.md             # Full architecture documentation
└── README.md                   # This file
```

---

## 📊 Autoscaling Behavior

| SQS Queue Depth | Replicas | Cost Impact |
|---|---|---|
| 0 messages | **0 pods** (scale to zero) | Zero compute cost |
| 1–5 messages | 1 pod | Minimal |
| 6–10 messages | 2 pods | — |
| 11–15 messages | 3 pods | — |
| 16–20 messages | 4 pods | — |
| 20+ messages | **5 pods** (max) | Capped |

> **`queueLength: 5`** — KEDA creates 1 replica for every 5 messages in the queue.

---

## 🔐 Security Highlights

- **IRSA (no static credentials):** Pods receive temporary AWS credentials via OIDC — no `AWS_ACCESS_KEY` ever stored
- **GitHub OIDC for CI/CD:** GitHub Actions authenticates to AWS via OIDC — no secrets in GitHub
- **Pod Security Standards:** `keda-demo` namespace enforces `restricted` pod security profile
- **Network Policy:** Pods only allowed to reach SQS endpoint on port 443
- **Trivy:** Docker image scanned for HIGH/CRITICAL CVEs in every CI run

---

## 💰 AWS Cost Estimate

> Running this project for 30 days, ~1 hour/day of active testing:

| Service | Cost |
|---|---|
| EKS Control Plane | ~$2.40 (30 days × $0.10/hr × 0.8hr) |
| EC2 t3.micro (1 node) | Free Tier (750 hrs/month) |
| Amazon SQS | Free Tier (first 1M requests/month) |
| Amazon ECR | Free Tier (500 MB/month) |
| **Total (approx.)** | **~$2.40/month** |

> See `docs/cost-analysis.md` for a full breakdown and Free Tier optimization tips.

---

## 📚 Key Learning Resources

- [KEDA Documentation](https://keda.sh/docs/)
- [KEDA AWS SQS Scaler](https://keda.sh/docs/scalers/aws-sqs/)
- [EKS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Terraform AWS EKS Module](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)

---

## 📅 Build Journey

This project was built over **30 days at 1 hour/day** as a structured portfolio challenge.
See [`docs/day-by-day-log.md`](./docs/day-by-day-log.md) for the full daily progress log.

---

## 📄 License

MIT License — see [LICENSE](./LICENSE) for details.

---

## 🙋 Author

**Harshad S** — [GitHub @Harshads-git](https://github.com/Harshads-git)

> *Inspired by [ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo](https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo) — re-implemented from scratch on AWS.*
