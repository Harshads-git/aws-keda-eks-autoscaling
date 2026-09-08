# Security Guide: Defense-in-Depth for KEDA on EKS

This guide explains the complete security model: how RBAC, Pod Security Standards,
IRSA, NetworkPolicy, and Secrets Management work together as independent layers,
each limiting blast radius if another layer is compromised.

---

## 1. Security Architecture Overview

```
Request path: Consumer pod → SQS API
  Layer 1: IRSA (AWS IAM)        ← which AWS actions are allowed
  Layer 2: NetworkPolicy         ← which IPs/ports the pod can reach
  Layer 3: Pod Security Context  ← what the container process can do on the node
  Layer 4: K8s RBAC              ← what the ServiceAccount can do to the K8s API
  Layer 5: ResourceQuota         ← how much cluster resources can be consumed
```

Each layer is independent. Bypassing one does not bypass others.

---

## 2. IRSA — Least-Privilege AWS Permissions

Defined in [`terraform/modules/irsa/main.tf`](../terraform/modules/irsa/main.tf).

### What the consumer IAM role is allowed to do

```json
{
  "Effect": "Allow",
  "Action": [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes"
  ],
  "Resource": "arn:aws:sqs:us-east-1:183264980:keda-demo-queue"
}
```

### What it is NOT allowed to do

```
❌ sqs:SendMessage          — cannot write to the queue (only reads)
❌ sqs:DeleteQueue          — cannot delete the queue itself
❌ sqs:*                    — no wildcard permissions
❌ s3:*                     — no S3 access
❌ ec2:*                    — no EC2 access
❌ iam:*                    — cannot create/modify IAM roles
```

### How IRSA works (trust chain)

```
1. EKS cluster has an OIDC provider URL (set up by Terraform)
2. Consumer pod gets a projected ServiceAccount token (auto-mounted)
3. boto3 detects AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE env vars
4. boto3 calls sts:AssumeRoleWithWebIdentity with the SA token
5. AWS STS verifies token against OIDC provider
6. STS returns temporary credentials (valid ~1 hour, auto-refreshed)
7. boto3 uses temp credentials for all SQS API calls
```

No static `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` anywhere in the cluster.

---

## 3. Kubernetes RBAC

Defined in [`manifests/rbac.yaml`](../manifests/rbac.yaml).

### What the consumer ServiceAccount CAN do

| Resource | Actions | Scope |
|---|---|---|
| `configmaps` | get, watch, list | Only `keda-demo-config` (by name) |
| `pods` | get | Own pod only (via token identity) |

### What the consumer ServiceAccount CANNOT do

```bash
# Test with kubectl auth can-i:
kubectl auth can-i get secrets \
  --as=system:serviceaccount:keda-demo:keda-demo -n keda-demo
# → no

kubectl auth can-i create pods \
  --as=system:serviceaccount:keda-demo:keda-demo -n keda-demo
# → no

kubectl auth can-i get pods -n kube-system \
  --as=system:serviceaccount:keda-demo:keda-demo
# → no (RBAC is namespace-scoped, can't cross namespace boundary)
```

### Why RBAC matters even with IRSA

An attacker who compromises a consumer pod gets:
- The pod's ServiceAccount token (mounted at `/var/run/secrets/kubernetes.io/...`)
- This token has ONLY the permissions defined in the Role

With least-privilege RBAC:
```
Compromised pod → SA token → K8s API
→ Can read: keda-demo-config (not useful to attacker)
→ Cannot: read secrets, create pods, access other namespaces
→ Blast radius: minimal
```

Without RBAC (default ServiceAccount):
```
Default SA has no permissions in a hardened cluster (also safe)
BUT: cluster-admin bindings on default SA = cluster takeover risk
```

---

## 4. Pod Security Standards (PSS)

Enforced via namespace labels in [`manifests/namespace.yaml`](../manifests/namespace.yaml).

### Three PSS levels

| Level | Description | What it blocks |
|---|---|---|
| `privileged` | No restrictions | Nothing |
| `baseline` | Minimal sanity | Host namespaces, privileged containers |
| `restricted` | Hardened | Everything baseline + non-root requirement, seccomp |

This project uses **`restricted`** on the `keda-demo` namespace.

### What `restricted` enforces on every pod

```yaml
# These fields MUST be set correctly or pod is REJECTED:
securityContext:
  runAsNonRoot: true            # Cannot run as root (UID 0)
  runAsUser: ≥ 1               # Must have explicit non-root UID
  seccompProfile:
    type: RuntimeDefault        # Must have seccomp profile

containers[].securityContext:
  allowPrivilegeEscalation: false  # Cannot sudo/setuid
  capabilities:
    drop: [ALL]                    # No Linux capabilities
```

### Verify PSS is enforcing

```bash
# Attempt to run a privileged pod in keda-demo namespace:
kubectl run bad-pod \
  --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"bad-pod","image":"nginx","securityContext":{"privileged":true}}]}}' \
  -n keda-demo

# Expected output:
# Error from server (Forbidden):
#   pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest"
```

---

## 5. Pod Security Context

Defined in [`manifests/deployment.yaml`](../manifests/deployment.yaml).

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001           # Non-root UID (app.py runs as this user)
  runAsGroup: 1001
  fsGroup: 1001
  seccompProfile:
    type: RuntimeDefault    # Kernel syscall filter (reduces attack surface)

containers[].securityContext:
  allowPrivilegeEscalation: false  # Prevents setuid/setgid exploits
  readOnlyRootFilesystem: false    # app.py writes /tmp/healthy
  capabilities:
    drop: [ALL]             # No NET_ADMIN, no SYS_ADMIN, no CAP_NET_RAW, etc.
```

### What dropping ALL capabilities prevents

```
CAP_NET_ADMIN:  Cannot modify network interfaces, firewall rules
CAP_SYS_ADMIN:  Cannot mount filesystems, change namespaces
CAP_NET_RAW:    Cannot craft raw packets (ARP spoofing, ICMP floods)
CAP_SETUID:     Cannot change process UID (no privilege escalation)
```

A compromised process in the container can't do any of the above even if
it gains code execution — the kernel enforces these limits.

---

## 6. Secrets Management Decision Tree

```
What type of value is it?

AWS credential (access key, secret key)
  └─ Use IRSA → no static credentials anywhere ✓

Non-sensitive configuration (queue URL, region, log level)
  └─ Use ConfigMap → easy to read, no encryption overhead ✓

Sensitive value (password, API key, webhook secret, TLS cert)
  ├─ Small team, simple setup
  │   └─ Use K8s Secret (base64 encoded, encrypted at rest if KMS enabled)
  └─ Audit trail required / rotation needed / cross-service sharing
      └─ Use AWS Secrets Manager + Secrets Store CSI Driver
         └─ See manifests/secrets-manager-stub.yaml ✓

K8s control plane bootstrap secret (e.g. CA cert)
  └─ Use K8s Secret (managed by cluster) ✓
```

### Enable KMS encryption for Kubernetes Secrets

```hcl
# In terraform/modules/eks/main.tf:
resource "aws_eks_cluster" "main" {
  encryption_config {
    resources = ["secrets"]  # Encrypt all K8s Secrets with KMS
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }
}
```

Without this: K8s Secrets are base64 encoded but NOT encrypted in etcd.

---

## 7. Security Checklist

```
☑ IRSA: no static AWS credentials, scoped to specific SQS queue
☑ RBAC: consumer SA can only read its own ConfigMap + own Pod
☑ Pod Security Standards: 'restricted' enforced on namespace
☑ runAsNonRoot: container runs as UID 1001
☑ seccompProfile: RuntimeDefault (kernel syscall filter)
☑ capabilities: drop ALL (no Linux capabilities)
☑ NetworkPolicy: deny all ingress, allow only DNS + HTTPS egress
☑ ResourceQuota: caps namespace CPU/memory/pod count
☑ PodDisruptionBudget: protects against voluntary disruptions

Recommended additions:
☐ KMS encryption for K8s Secrets at rest (terraform/modules/eks/main.tf)
☐ AWS Secrets Manager for any actual passwords/API keys (secrets-manager-stub.yaml)
☐ Enable AWS CloudTrail for IAM audit log
☐ Enable EKS audit logs → CloudWatch Logs for K8s API audit trail
☐ AWS GuardDuty for runtime threat detection (watches EKS API + EC2)
```
