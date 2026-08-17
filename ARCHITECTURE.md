# Architecture: AWS KEDA EKS Event-Driven Autoscaling

## 1. Project Overview

This project is an **original AWS portfolio implementation** inspired by the event-driven autoscaling patterns demonstrated in [gcp-keda-gke-event-driven-autoscaling-demo](https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo).

Every component has been re-architected from the ground up using AWS-native services, while preserving the core concept: **KEDA (Kubernetes Event-Driven Autoscaling) scales a workload to zero — and back up — based on the depth of a message queue**.

---

## 2. The Core Concept: Event-Driven Autoscaling

Traditional Kubernetes autoscaling (HPA) relies on **CPU and memory** metrics. This is reactive and imprecise for queue-based workloads:

- A queue consumer pod can be **idle** (CPU ≈ 0%) while **100,000 messages** pile up.
- A queue consumer pod can be **saturated** while the queue is empty.

**KEDA solves this** by scaling based on the **actual business metric** — the number of messages waiting in the queue:

```
Messages in Queue → KEDA reads metric → Creates/updates HPA → K8s scales pods
```

When the queue is empty → `replicas = 0` (scale to zero, zero cost).
When messages arrive → `replicas = ceil(queue_depth / target_per_replica)`.

---

## 3. GCP → AWS Service Translation

| Layer | GCP (Reference) | AWS (This Project) | Why This AWS Service |
|---|---|---|---|
| **Kubernetes** | GKE (Google Kubernetes Engine) | Amazon EKS | Managed K8s, KEDA runs identically on both |
| **Message Queue** | Cloud Pub/Sub | Amazon SQS | KEDA has a native, battle-tested SQS scaler |
| **Container Registry** | GCR / Artifact Registry | Amazon ECR | Private registry, IAM-integrated, co-located with EKS |
| **Pod Identity** | Workload Identity (GKE) | IRSA (IAM Roles for Service Accounts) | Zero static credentials in pods |
| **CLI** | `gcloud` | `aws` CLI v2 | AWS's primary control plane tool |
| **Monitoring** | Cloud Monitoring | Amazon CloudWatch | Native AWS metrics and logs |
| **Cloud IAM** | GCP IAM + Service Accounts | AWS IAM Roles & Policies | Fine-grained permission control |
| **IaC** | Not included in reference | Terraform | Industry-standard, cloud-agnostic IaC |
| **CI/CD** | Not included in reference | GitHub Actions + OIDC | Automated build/deploy with zero stored secrets |

---

## 4. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        AWS Account (us-east-1)                       │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     VPC (10.0.0.0/16)                          │  │
│  │                                                                │  │
│  │  ┌──────────────────────┐   ┌──────────────────────────────┐  │  │
│  │  │  Public Subnets      │   │     Private Subnets          │  │  │
│  │  │  (Load Balancers)    │   │     (EKS Worker Nodes)       │  │  │
│  │  │  10.0.1.0/24         │   │     10.0.10.0/24             │  │  │
│  │  │  10.0.2.0/24         │   │     10.0.11.0/24             │  │  │
│  │  └──────────────────────┘   │                              │  │  │
│  │                              │  ┌────────────────────────┐ │  │  │
│  │                              │  │   Amazon EKS Cluster   │ │  │  │
│  │                              │  │                        │ │  │  │
│  │                              │  │  ┌──────────────────┐  │ │  │  │
│  │                              │  │  │  KEDA Operator   │  │ │  │  │
│  │                              │  │  │  (keda namespace) │  │ │  │  │
│  │                              │  │  │  IRSA Role ──────┼──┼─┼──┼──┤──▶ AWS STS
│  │                              │  │  └────────┬─────────┘  │ │  │  │
│  │                              │  │           │ manages     │ │  │  │
│  │                              │  │           ▼             │ │  │  │
│  │                              │  │  ┌──────────────────┐  │ │  │  │
│  │                              │  │  │   HPA (managed   │  │ │  │  │
│  │                              │  │  │   by KEDA)       │  │ │  │  │
│  │                              │  │  └────────┬─────────┘  │ │  │  │
│  │                              │  │           │ scales      │ │  │  │
│  │                              │  │           ▼             │ │  │  │
│  │                              │  │  ┌──────────────────┐  │ │  │  │
│  │                              │  │  │  keda-demo Pods  │  │ │  │  │
│  │                              │  │  │  (SQS Consumer)  │  │ │  │  │
│  │                              │  │  │  0 → 5 replicas  │  │ │  │  │
│  │                              │  │  │  IRSA Role ───── ┼──┼─┼──┼──┤──▶ SQS
│  │                              │  │  └──────────────────┘  │ │  │  │
│  │                              │  └────────────────────────┘ │  │  │
│  │                              └──────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────────┐ │
│  │  Amazon SQS     │  │  Amazon ECR      │  │  Amazon CloudWatch  │ │
│  │  keda-demo-queue│  │  keda-demo-app   │  │  Metrics + Logs     │ │
│  │  keda-demo-dlq  │  │  (Docker images) │  │  Container Insights │ │
│  └─────────────────┘  └──────────────────┘  └─────────────────────┘ │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

External:
  Message Producer (scripts/generate-messages.sh) ──▶ SQS Queue
  GitHub Actions (CI/CD) ──OIDC──▶ AWS IAM ──▶ ECR + EKS
```

---

## 5. KEDA Scaling Logic (Deep Dive)

### 5.1 The ScaledObject

KEDA uses a Custom Resource called `ScaledObject` to define the scaling behavior:

```yaml
spec:
  minReplicaCount: 0      # Scale TO ZERO when queue is empty
  maxReplicaCount: 5      # Never exceed 5 pods
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueLength: "5"  # Target: 1 replica per 5 messages
```

**Scaling Formula:**
```
desired_replicas = ceil(ApproximateNumberOfMessages / queueLength)

Examples:
  0 messages  →  ceil(0/5)  = 0 replicas  (scale to zero)
  3 messages  →  ceil(3/5)  = 1 replica
  11 messages →  ceil(11/5) = 3 replicas
  25 messages →  ceil(25/5) = 5 replicas (capped at maxReplicaCount)
```

### 5.2 KEDA Internal Components

```
ScaledObject
    │
    ├── KEDA Operator (watches ScaledObjects, creates/manages HPA)
    │
    └── KEDA Metrics Adapter (extends K8s metrics API with external metrics)
              │
              └── Calls AWS SQS GetQueueAttributes API via IRSA
                        │
                        └── Returns ApproximateNumberOfMessages
```

---

## 6. Security Design: IRSA (IAM Roles for Service Accounts)

### The Problem with Static Credentials

❌ **Anti-pattern:** Store `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` in a Kubernetes Secret. Any pod that can read secrets in that namespace gains permanent AWS access.

### The IRSA Solution

IRSA works through **OIDC federation** — the same mechanism GitHub Actions uses for AWS access:

```
1. Pod starts → K8s injects a signed JWT (projected ServiceAccount token)
2. Pod's boto3/AWS SDK calls STS AssumeRoleWithWebIdentity
3. AWS STS validates JWT signature against EKS's OIDC public key
4. STS issues temporary credentials (valid 1 hour, auto-refreshed)
5. Credentials are scoped to exactly the IAM Role — no more, no less
```

**Two separate IRSA roles in this project:**

| Role | Principal | Permissions |
|---|---|---|
| `keda-operator-role` | `keda` namespace / `keda-operator` SA | `sqs:GetQueueAttributes`, `cloudwatch:GetMetricData` |
| `keda-demo-app-role` | `keda-demo` namespace / `keda-demo` SA | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility` |

---

## 7. SQS vs. Cloud Pub/Sub: Key Differences

| Concept | Cloud Pub/Sub | Amazon SQS |
|---|---|---|
| **Delivery model** | Push (subscription receives messages) or Pull | Pull only (consumers poll) |
| **Acknowledgment** | `message.ack()` | `DeleteMessage` API call |
| **Visibility** | Message removed after ack | Message hidden (visibility timeout) until deleted |
| **Dead letters** | Dead letter topic | Dead letter queue (separate SQS queue) |
| **KEDA metric** | `num_undelivered_messages` | `ApproximateNumberOfMessages` |
| **Ordering** | Pub/Sub supports ordered subscriptions | Standard SQS: best-effort ordering |
| **Max message size** | 10 MB | 256 KB |
| **Retention** | 7 days | 1–14 days (configurable) |

**Why SQS is better suited for this demo:**
- KEDA's SQS scaler is mature and well-documented
- Pull model is simpler to reason about for scale-to-zero
- No push endpoint configuration needed

---

## 8. Networking Design

```
VPC: 10.0.0.0/16
│
├── AZ us-east-1a
│   ├── Public Subnet:  10.0.1.0/24   (Internet Gateway, NAT Gateway)
│   └── Private Subnet: 10.0.10.0/24  (EKS nodes, pods)
│
└── AZ us-east-1b
    ├── Public Subnet:  10.0.2.0/24   (Internet Gateway)
    └── Private Subnet: 10.0.11.0/24  (EKS nodes, pods)
```

**Why private subnets for EKS nodes?**
- Nodes are not directly reachable from the internet
- All outbound traffic goes through NAT Gateway (controlled egress)
- Pods communicate with SQS via VPC Endpoint (optional, reduces NAT cost)

---

## 9. CI/CD Pipeline Architecture

```
Developer pushes to GitHub
         │
         ▼
GitHub Actions (CI) ──OIDC──▶ AWS IAM Role (GitHub Actions)
         │                            │
         │                            ▼
         │                    ECR: docker push image:sha
         │
         ▼ (on merge to main)
GitHub Actions (CD) ──OIDC──▶ AWS IAM Role (GitHub Actions)
         │                            │
         │                            ▼
         │                    EKS: kubectl set image
         │                    kubectl rollout status
         │
         ▼
   ✅ Deployment Complete
```

---

## 10. Repository Reference

- **Inspiration:** [ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo](https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo)
- **KEDA SQS Scaler docs:** https://keda.sh/docs/scalers/aws-sqs/
- **IRSA documentation:** https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- **KEDA TriggerAuthentication (AWS):** https://keda.sh/docs/authentication-providers/aws/
