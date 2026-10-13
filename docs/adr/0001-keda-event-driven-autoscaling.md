# ADR 0001: Adoption of KEDA for Event-Driven Autoscaling

* **Status:** Accepted
* **Date:** 2026-10-13
* **Deciders:** Cloud Platform & Engineering Architecture Team
* **Consulted:** DevOps, SRE, Application Developers

---

## 1. Context & Problem Statement

In an event-driven worker system consuming messages from Amazon SQS, workloads exhibit sharp, non-deterministic arrival spikes followed by extended periods of complete inactivity.

Standard Kubernetes Horizontal Pod Autoscaling (HPA) primarily scales workloads based on resource utilization metrics (CPU and Memory). However:
1. **CPU/Memory is a lagging indicator:** Worker pods processing lightweight message batches might not experience high CPU or memory utilization even while thousands of unprocessed messages queue up in SQS.
2. **Cannot scale to zero:** Standard Kubernetes HPA requires at least one replica running (`minReplicas >= 1`). Idle worker pods continuously consume cluster compute resources, violating cloud cost efficiency goals.
3. **Slow scale-up reaction:** By the time CPU utilization increases across existing pods, queue depth and message latency have already breached Service Level Objectives (SLOs).

We need an autoscaling mechanism that scales based directly on **queue backlog depth (lead metric)**, scales **to zero** during quiet periods, and reactively scales out to accommodate bursts.

---

## 2. Decision Drivers

* **Direct Queue Metric Coupling:** Scale directly proportional to SQS `ApproximateNumberOfMessages`.
* **Zero-Resource Idle Cost:** Ability to scale to zero pods when queue backlog is 0.
* **Rapid Scale-Up Latency:** Minimize reaction time from message arrival to pod provisioning.
* **Security & IAM Integration:** Support AWS IAM Roles for Service Accounts (IRSA) without storing static long-lived credentials in cluster secrets.
* **Extensibility:** Standard Kubernetes Custom Resource Definitions (CRDs) with support for multi-queue triggers, fallback mechanisms, and Prometheus metric export.

---

## 3. Considered Options

* **Option 1:** Native Kubernetes HPA with CPU and Memory Metrics
* **Option 2:** Custom Metric Server (Prometheus Adapter + HPA)
* **Option 3:** KEDA (Kubernetes Event-driven Autoscaling)

---

## 4. Evaluation of Options

### Option 1: Native HPA (CPU / Memory)
* **Pros:** Built into core Kubernetes; zero external CRDs or controllers to install.
* **Cons:** Cannot scale to 0. Lagging indicator. No visibility into external message queues. High idle infrastructure costs on AWS EKS.

### Option 2: Prometheus Adapter + HPA
* **Pros:** Can query Prometheus metrics scraped from CloudWatch or SQS exporter.
* **Cons:** Complex pipeline (SQS -> CloudWatch -> Prometheus Scraper -> Prometheus Adapter -> HPA). Metric latency is compounded (often 2–5 minute lag). Still cannot scale to 0 without third-party workarounds. High operational overhead.

### Option 3: KEDA (Kubernetes Event-driven Autoscaling)
* **Pros:**
  * Native scale-to-zero and scale-from-zero via internal ScaledObject controller.
  * Direct SQS trigger adapter polling queue attributes every 15–30 seconds.
  * Generates and manages the underlying Kubernetes HPA automatically.
  * Built-in `TriggerAuthentication` supporting IRSA (`podIdentity: aws-irsa`).
  * CNCF Graduated project with enterprise-grade stability and active community.
  * Exposes rich Prometheus metrics out-of-the-box (`keda_scaler_metrics_value`, `keda_scaled_object_errors`).
* **Cons:**
  * Additional cluster controller and CRDs to maintain.
  * Direct SQS polling requires IAM read permissions on the target queue.

---

## 5. Decision Outcome

**Chosen Option:** **Option 3: KEDA**

We adopted KEDA as the standard autoscaling mechanism for all queue-driven worker workloads in SmartScale AI.

### Architectural Blueprint

```
[ Amazon SQS Queue ]
        │
        │ Polls ApproximateNumberOfMessages
        ▼
[ KEDA Operator (keda-operator) ]
        │
        ├── Queue > 0 ──▶ Scale 0 → 1 (KEDA activator creates first pod)
        └── Queue > Threshold ──▶ Hands off target tracking to Kubernetes HPA
                                      │
                                      ▼
                        [ keda-demo Worker Deployment ]
```

---

## 6. Consequences & Operational Mitigations

### Positive Consequences
* **95%+ Idle Cost Reduction:** In non-production and off-peak periods, consumer pods scale completely to 0, eliminating unused compute allocations.
* **Sub-Minute Burst Scaling:** When batch loads or traffic spikes hit SQS, KEDA triggers scale-up within 15–30 seconds.
* **Standardized Infrastructure as Code:** ScaledObjects are declared as plain Kubernetes YAML manifests and managed through our GitOps pipeline (ArgoCD).

### Negative Consequences & Mitigations
* **Cold Start Latency:** When scaling from 0 to 1, pod scheduling and container image pull introduce an initial 10–25s delay.
  * *Mitigation:* In production, `minReplicaCount` can be set to 1 if sub-second latency is required, while keeping `minReplicaCount: 0` for development and batch queues. Pre-pull container images on cluster nodes using daemonsets.
* **SQS API Request Costs:** Continuous polling by KEDA makes API calls to `sqs:GetQueueAttributes`.
  * *Mitigation:* Set `pollingInterval: 30` (or `60` during low-traffic tiers) to stay well within AWS Free Tier limits (1M requests/month free).
