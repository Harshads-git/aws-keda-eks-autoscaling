# Cost Optimization Guide: Spot Instances + Savings Strategies

This guide explains the cost optimization strategies applied to this project,
with a focus on EC2 Spot instances for the consumer workload.

---

## 1. Cost Breakdown: On-Demand vs Spot

### Current (On-Demand only)

| Component | Type | Cost/hr | Cost/month |
|---|---|---|---|
| EKS Control Plane | Managed (always) | $0.10 | $73.00 |
| Worker Node | t3.micro On-Demand | $0.0104 | $7.59 |
| NAT Gateway | (per AZ) | $0.045 | $32.85 |
| SQS API calls | ~3,600/hr empty polls | ~$0.00 | ~$0.50 |
| **Total (idle)** | | **$0.1554** | **$113.94** |

### With Spot (optimized)

| Component | Type | Cost/hr | Cost/month |
|---|---|---|---|
| EKS Control Plane | Managed (always) | $0.10 | $73.00 |
| On-Demand Node | t3.micro (1 node, system pods) | $0.0104 | $7.59 |
| Spot Node | t3.small Spot (avg, when active) | $0.0041 | ~$3.00 |
| NAT Gateway | (per AZ) | $0.045 | $32.85 |
| **Total (1 Spot active)** | | **$0.1595** | **$116.44** |

> **Key insight**: EKS control plane ($73/month) dominates. The node cost
> difference is marginal on 1-2 nodes. Spot savings matter most at scale
> (10+ nodes handling burst traffic).

### At Scale (5 Spot nodes active under heavy load)

| Scenario | Nodes | Node cost/hr | Savings vs On-Demand |
|---|---|---|---|
| On-Demand (t3.small) | 5 | 5 × $0.023 = $0.115 | baseline |
| Spot (t3.small) | 5 | 5 × $0.004 = $0.020 | **-83%** |
| Spot (mixed fleet) | 5 | 5 × $0.005 = $0.025 | **-78%** |

At 5 nodes the savings are significant: **$85/month in node costs** for constant workloads.

---

## 2. The Spot Reliability Model for KEDA Workloads

### Why KEDA workloads tolerate Spot better than other workloads

| Workload type | Spot suitability | Reason |
|---|---|---|
| Stateful (database) | ❌ Poor | Data loss risk on interruption |
| Long-running jobs | ❌ Poor | May need to restart from scratch |
| Web servers | 🟡 Moderate | Load balancer redirects, brief downtime |
| **Queue consumers (KEDA)** | ✅ Excellent | SQS redelivers interrupted messages |

### Interruption sequence (what actually happens)

```
t=0:00  AWS decides to reclaim Spot instance
t=0:00  EC2 metadata service returns interruption notice at:
        http://169.254.169.254/latest/meta-data/spot/interruption-action
t=0:00  aws-node-termination-handler (NTH) detects notice
t=0:01  NTH cordons node: kubectl cordon <node> (no new pods scheduled)
t=0:01  NTH drains node: kubectl drain <node> --grace-period=30
t=0:01  Kubernetes sends SIGTERM to consumer pod
t=0:01  app.py signal handler sets self._running = False
t=0:31  Consumer pod exits cleanly (terminationGracePeriodSeconds=40)
t=0:31  If message was being processed: either deleted (success) or
        left in queue (failure) → redelivered after 30s visibility timeout
t=2:00  AWS terminates EC2 instance
t=3:00  Cluster Autoscaler detects missing node → starts replacement Spot
t=5:00  New Spot node joins cluster → evicted pods rescheduled
```

**Result**: at most **1 message** may be reprocessed (if interrupted mid-delete).
This is acceptable for idempotent workloads.

---

## 3. Spot Instance Selection Strategy

### Instance type diversity (pool stability)

```
AWS Spot availability pools: 1 pool = 1 instance type in 1 AZ
  us-east-1a  t3.small  = Pool A
  us-east-1b  t3.small  = Pool B
  us-east-1a  t3a.small = Pool C
  ...

More pools = more alternatives when one pool is exhausted
```

Our configuration uses **5 instance types** across **2-3 AZs** = 10-15 pools.
If t3.small us-east-1a is interrupted, CA tries t3a.small us-east-1a first,
then t3.small us-east-1b, etc.

### Spot interruption rates (EC2 Spot Advisor)

```
Rate   Instance type   Notes
< 5%   t3a.small       AMD, less popular = less competition
< 5%   t3a.medium      AMD variant
5-10%  t3.small        Popular, higher demand
5-10%  t3.medium       Popular, higher demand
< 5%   m5.large        Good alternative pool
```

Check live rates: https://aws.amazon.com/ec2/spot/instance-advisor/

---

## 4. Additional Cost Optimizations

### 4a. Scale to Zero (KEDA's Biggest Win)

```
Traditional deployment (min replicas = 1):
  Cost: 1 pod running 24/7 even when no messages
  Node stays warm: $0.0104/hr minimum

KEDA (min replicas = 0):
  Queue empty: 0 pods → node stays but idle (still costs $0.0104/hr for node)
  Actually scale node to 0: need CA min_size=0 for Spot group
    With min_size=0: Spot nodes scale to 0 when no consumer pods needed
    Only On-Demand t3.micro stays (for KEDA operator + system pods)
  Net save: Spot node cost ($0.004/hr) when queue is empty
```

### 4b. NAT Gateway Cost Reduction

NAT Gateway at $0.045/hr ($33/month) is expensive for a demo. Alternatives:

```bash
# Option 1: Use VPC Endpoints (remove NAT Gateway entirely)
# Covered in terraform/modules/vpc/main.tf when vpc_endpoints_enabled=true
# Add endpoints for: SQS, STS, ECR, EKS
# Cost: $0.01/hr per endpoint × 4 = $0.04/hr (cheaper than NAT)

# Option 2: Public subnets for nodes (no NAT needed)
# Nodes get public IPs → direct internet access
# Security tradeoff: nodes are publicly routable
# For demos only — not for production
```

### 4c. Destroy When Not Using

```bash
# Destroy entire stack when done (no active demo):
cd terraform
terraform destroy -var-file=terraform.tfvars

# What this saves:
# EKS control plane: $0.10/hr → $0 (biggest saving)
# All nodes: $0/hr
# NAT Gateway: $0.045/hr → $0
# SQS: pay-per-use only (~$0.00/month idle)

# Re-create when needed:
terraform apply  # ~15 minutes to rebuild everything
```

---

## 5. Cost Monitoring with Prometheus

With monitoring enabled, track costs in Grafana:

```promql
# Approximate cost per message processed ($0.10/hr EKS ÷ throughput)
# (rough model: higher throughput = lower cost per message)
0.10 / (rate(keda_demo_messages_processed_total[1h]) * 3600)

# Node count over time (track Spot node additions)
count(kube_node_info) by (instance_type)

# Spot vs On-Demand node split
count(kube_node_labels{label_keda_demo_node_class="spot"})
/
count(kube_node_info)
```

---

## 6. Production Cost Architecture

For a production system handling sustained load:

```
                        ┌──────────────────┐
                        │  System Node     │ On-Demand t3.small
                        │  KEDA + system   │ $0.023/hr (always on)
                        └──────────────────┘

On light load:          ┌──────────────────┐
                        │  Spot Node 1     │ t3a.small Spot
                        │  consumer pods   │ $0.003/hr
                        └──────────────────┘

On heavy load:          ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐
                        │Sp1 │ │Sp2 │ │Sp3 │ │Sp4 │ │Sp5 │
                        │    │ │    │ │    │ │    │ │    │
                        └────┘ └────┘ └────┘ └────┘ └────┘
                        5 × ~$0.004/hr = $0.020/hr (+$14.60/month)

Total at max load: $0.10 + $0.023 + $0.020 = $0.143/hr ($104/month)
vs On-Demand equivalent: $0.10 + $0.023 + $0.115 = $0.238/hr ($173/month)
Saving: ~40% at scale
```
