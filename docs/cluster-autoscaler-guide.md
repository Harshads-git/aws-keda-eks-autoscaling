# Cluster Autoscaler Guide: Node Scaling for KEDA Workloads

This guide explains how the Kubernetes Cluster Autoscaler works alongside KEDA,
when each layer triggers, and how to observe both in action.

---

## 1. The Two-Level Autoscaling Model

This project implements **two distinct autoscalers** that work at different layers:

```
                    ┌─────────────────────────────────┐
                    │         SQS Queue                │
                    │   ApproximateNumberOfMessages    │
                    └──────────────┬──────────────────┘
                                   │
                                   ▼ KEDA reads every 15s
                    ┌─────────────────────────────────┐
                    │    KEDA Operator                 │  ← Layer 1: Pod Scaler
                    │    ceil(N/5) = desired replicas  │
                    └──────────────┬──────────────────┘
                                   │
                                   ▼ creates/deletes pods
                    ┌─────────────────────────────────┐
                    │    EKS Node (t3.small, 2GB)      │
                    │    [pod1][pod2][pod3][pod4]       │
                    │    FULL - new pods go Pending    │
                    └──────────────┬──────────────────┘
                                   │ Pending pods detected
                                   ▼ every 30s scan
                    ┌─────────────────────────────────┐
                    │    Cluster Autoscaler            │  ← Layer 2: Node Scaler
                    │    SetDesiredCapacity(2)         │
                    └──────────────┬──────────────────┘
                                   │
                                   ▼ ~3-5 minutes
                    ┌─────────────────────────────────┐
                    │    New EC2 Node joins cluster    │
                    │    [pod5][pod6][pod7]...         │
                    └─────────────────────────────────┘
```

| Dimension | KEDA | Cluster Autoscaler |
|---|---|---|
| **Scales** | Pods (0 → 5) | Nodes (1 → 3) |
| **Trigger** | SQS queue depth | Pending pods |
| **Speed** | ~30-45 seconds | ~3-5 minutes |
| **Cost impact** | Pod scheduling | EC2 instance cost |
| **Scale-to-zero** | ✅ Yes (0 pods) | ❌ No (min 1 node) |
| **GCP equivalent** | KEDA / HPA | GKE node auto-provisioner |

---

## 2. One-Time Setup

```bash
# 1. Terraform creates the CA IAM role (terraform apply already done this):
terraform output -raw cluster_autoscaler_role_arn
# → arn:aws:iam::183264980:role/keda-demo-dev-cluster-cluster-autoscaler

# 2. Install CA via Helm:
bash scripts/install-cluster-autoscaler.sh

# 3. Verify:
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
# NAME                                              READY   STATUS    RESTARTS
# cluster-autoscaler-aws-cluster-autoscaler-xxxx    1/1     Running   0
```

---

## 3. How CA Discovers Node Groups

CA uses **AWS resource tags** to find which Auto Scaling Groups to manage.
These tags are set by Terraform in `terraform/modules/eks/node-group.tf`:

```hcl
tags = {
  "k8s.io/cluster-autoscaler/enabled"                   = "true"
  "k8s.io/cluster-autoscaler/${local.cluster_name}"     = "owned"
}
```

CA scans all ASGs with these tags every 30 seconds. It reads:
- `DesiredCapacity` — current node count
- `MinSize` / `MaxSize` — bounds (from `node_min_size=1`, `node_max_size=3`)

No kubeconfig needed — CA uses IAM + AWS API directly.

---

## 4. Triggering Node Scale-Up

For the demo, trigger scale-up by creating more pods than fit on one node:

```bash
# Send many messages to create Pending pods:
bash scripts/generate-messages.sh --count 100

# Watch CA decision in logs (separate terminal):
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-cluster-autoscaler \
  -f | grep -E "Scale-up|scale_up|node group"

# Watch nodes appear:
kubectl get nodes -w
# NAME                          STATUS   ROLES    AGE     VERSION
# ip-10-0-3-xxx.ec2.internal    Ready    <none>   2h      v1.29.x   ← existing
# ip-10-0-4-yyy.ec2.internal    Ready    <none>   3m      v1.29.x   ← NEW!
```

---

## 5. CA Scale-Down Behaviour

CA removes a node when:
1. The node has been underutilized for `scale-down-unneeded-time` (10 minutes)
2. All pods on the node can be rescheduled on other nodes
3. The node group is above `min_size` (at least 1 node must remain)

```bash
# Watch CA consider scale-down:
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f \
  | grep -E "Scale-down|scale_down|removable"
```

**Scale-down timeline:**
```
Queue drains → KEDA scales pods to 0 (300s cooldown)
                        │
                        ▼ after 300s
Pods terminated → node is mostly empty
                        │
                        ▼ after 10 more minutes (scale-down-unneeded-time)
CA removes node → SetDesiredCapacity(1)
                        │
                        ▼ ~1 minute
EC2 instance terminated (billing stops)
```

---

## 6. Key CA Log Messages

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50
```

| Log message | Meaning |
|---|---|
| `Scale-up: setting group ... size to 2` | CA added a node |
| `Removing node ... it is not needed` | CA removing idle node |
| `Scale-down: no unneeded nodes` | All nodes are needed |
| `No pod is unschedulable` | KEDA pods all fit — no scale-up needed |
| `Failed to get tag` | ASG tags missing — check terraform apply |

---

## 7. Observing Both Autoscalers Simultaneously

```bash
# Terminal 1: watch pods
kubectl get pods -n keda-demo -w

# Terminal 2: watch nodes
kubectl get nodes -w

# Terminal 3: send messages (triggers KEDA)
bash scripts/generate-messages.sh --count 100

# Terminal 4: watch CA logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f
```

**Expected sequence:**
```
t=0s     Send 100 messages
t=15s    KEDA sees 100 messages → desired=5 pods (ceil(100/5))
t=30s    5 pods Pending (t3.micro only fits ~3-4 pods)
t=60s    CA detects Pending pods → SetDesiredCapacity(2)
t=3-5m   New node joins → Pending pods scheduled → Running
t=15m+   Messages processed → queue empty → KEDA scales pods to 0
t=25m+   Node underutilized for 10m → CA removes 2nd node
t=26m    Back to: 0 pods, 1 node
```

---

## 8. Cost Impact of Node Scaling

| Scenario | Nodes | Cost/hr |
|---|---|---|
| Queue empty (scale-to-zero) | 1 (min) | $0.10 (EKS) + $0.0104 (t3.micro) |
| Light load (fits 1 node) | 1 | $0.1104/hr |
| Heavy load (CA adds node) | 2 | $0.10 + $0.0208 = $0.1208/hr |
| Maximum load | 3 | $0.10 + $0.0312 = $0.1312/hr |

> The EKS control plane ($0.10/hr) is the dominant cost regardless of node count.
> Add nodes freely — they add only ~$0.01/hr each (t3.micro).

---

## 9. Troubleshooting

### CA pod is running but nodes never scale up

```bash
# Check CA found your node group:
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler \
  | grep "node group"
# Should see: "Refreshed ASG list, next refresh after..."

# Check ASG tags:
aws autoscaling describe-auto-scaling-groups \
  --filters Name=tag:k8s.io/cluster-autoscaler/keda-demo-dev-cluster,Values=owned \
  --query 'AutoScalingGroups[].AutoScalingGroupName'
# If empty: terraform apply didn't set the tags (check node-group.tf)
```

### Nodes added but pods still Pending

```bash
# Check if new node joined:
kubectl get nodes
# If node is NotReady: check node events
kubectl describe node <node-name> | grep -A 10 Events

# If node is Ready but pods still Pending:
kubectl describe pod <pending-pod> -n keda-demo | grep -A 5 Events
# Look for: "Insufficient memory" or "Insufficient CPU"
# Fix: upgrade instance type or reduce pod resource requests
```
