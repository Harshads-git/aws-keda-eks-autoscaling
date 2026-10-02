# GitOps Guide — ArgoCD with SmartScale AI

Continuous deployment via GitOps: Git as the single source of truth for
all Kubernetes cluster state in the SmartScale AI EKS deployment.

---

## 1. GitOps vs Traditional Deployment

| | Traditional (kubectl) | GitOps (ArgoCD) |
|---|---|---|
| **Source of truth** | Engineer's laptop | Git repository |
| **Deployment trigger** | Manual `kubectl apply` | Git commit → auto-sync |
| **Audit trail** | None (or kubectl audit logs) | Full Git history + ArgoCD events |
| **Drift detection** | None | ArgoCD alerts on any drift |
| **Rollback** | `kubectl rollout undo` | `git revert <sha>` |
| **Access control** | RBAC on kubectl | Git branch protection + ArgoCD RBAC |
| **Multi-env promotion** | Scripts / manual | Branch per env or Kustomize overlays |

**The GitOps promise:** If Git matches the cluster, the cluster is correct.
If they diverge (drift), ArgoCD self-heals within minutes.

---

## 2. Architecture

```
Developer
    │  git push
    ▼
GitHub (main branch)
    │  ArgoCD polls every 3 min
    │  OR webhook triggers instantly
    ▼
ArgoCD (argocd namespace)
    │  Compares: Git state vs Cluster state
    │  Drift detected → auto-apply (selfHeal: true)
    ▼
keda-demo namespace
    ├── keda-demo Deployment (SQS consumer)
    ├── keda-demo-dlq Deployment (DLQ processor)
    ├── keda-demo-multi-queue Deployment
    ├── prediction-api Deployment
    ├── ScaledObjects (KEDA)
    └── Services, ConfigMaps, Secrets

ArgoCD ──► Slack notification on sync failure
ArgoCD ──► GitHub commit status (✅ Synced / ❌ OutOfSync)
```

---

## 3. Installing ArgoCD on EKS

```bash
# Create argocd namespace and install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD components to be ready
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=120s

# Get initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d

# Port-forward to access the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
# Open: https://localhost:8080 (username: admin, password: from above)

# Or install ArgoCD CLI
# macOS: brew install argocd
# Linux: curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

# Login via CLI
argocd login localhost:8080 --username admin --password <password> --insecure
```

---

## 4. Deploying SmartScale AI via GitOps

```bash
# Step 1: Register GitHub repository (if private, provide SSH key or token)
argocd repo add https://github.com/Harshads-git/aws-keda-eks-autoscaling.git \
  --username Harshads-git \
  --password <github-token>

# Step 2: Apply the AppProject (security boundary)
kubectl apply -f gitops/argocd-project.yaml

# Step 3: Apply the Application (starts watching Git)
kubectl apply -f gitops/argocd-application.yaml

# Step 4: Trigger first sync
argocd app sync smartscale-ai

# Step 5: Watch sync progress
argocd app get smartscale-ai
# Expected output:
# Name:       smartscale-ai
# Project:    smartscale-ai
# Status:     Synced
# Health:     Healthy
# Repo:       https://github.com/Harshads-git/...
# Revision:   main
# Path:       manifests
```

---

## 5. Day-to-Day GitOps Workflow

### Deploying a Change

```bash
# 1. Edit a manifest
vim manifests/deployment.yaml

# 2. Commit and push
git add manifests/deployment.yaml
git commit -m "feat: update consumer image to v1.2.3"
git push origin main

# 3. ArgoCD auto-syncs (within 3 minutes)
# OR trigger immediately:
argocd app sync smartscale-ai

# 4. Monitor health
argocd app get smartscale-ai --watch
```

### Rollback to Previous Version

```bash
# View deployment history
argocd app history smartscale-ai
# ID  DATE       REVISION  SOURCE
# 1   2026-10-01 abc1234   manifests
# 2   2026-10-02 def5678   manifests

# Rollback to history ID 1
argocd app rollback smartscale-ai 1
# OR via git:
git revert def5678
git push origin main
# ArgoCD auto-syncs the revert
```

### Checking for Drift

```bash
# See difference between Git and cluster
argocd app diff smartscale-ai

# Example output when KEDA changes replicas (this is expected, not drift):
# ===== apps/Deployment keda-demo ======
# 7,7c7,7
# - replicas: 1    (Git)
# + replicas: 5    (cluster, managed by KEDA)
# → This diff is ignored via ignoreDifferences in argocd-application.yaml
```

---

## 6. KEDA + ArgoCD Integration Notes

KEDA and ArgoCD need careful coordination because KEDA **modifies** the
`spec.replicas` field that ArgoCD tracks:

| Scenario | Without `ignoreDifferences` | With `ignoreDifferences` |
|---|---|---|
| KEDA scales to 5 pods | ArgoCD fights KEDA → resets to 1 | ArgoCD ignores replica field ✅ |
| Manual `kubectl scale` | ArgoCD restores to Git value | ArgoCD restores to Git value ✅ |
| New commit changes replicas | ArgoCD applies | ArgoCD applies ✅ |

The `ignoreDifferences` setting in `argocd-application.yaml`:
```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas    # Let KEDA own this field
```

This is why GitOps + KEDA works: ArgoCD owns the **manifest structure**,
KEDA owns the **replica count**. No conflict.

---

## 7. Progressive Delivery with ArgoCD Rollouts

For zero-downtime deployments beyond standard Kubernetes rolling updates,
use **Argo Rollouts** (a separate controller):

```yaml
# gitops/rollout.yaml — Replace Deployment with Rollout
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: keda-demo
spec:
  strategy:
    canary:
      steps:
        - setWeight: 10    # Send 10% traffic to new version
        - pause: {duration: 2m}
        - setWeight: 50    # Send 50% traffic to new version
        - pause: {duration: 2m}
        - setWeight: 100   # Full rollout if healthy
  # ... rest is same as Deployment
```

```bash
# Monitor rollout progress
kubectl argo rollouts get rollout keda-demo -n keda-demo --watch

# Abort if metrics degrade
kubectl argo rollouts abort keda-demo -n keda-demo
```

---

## 8. Sync Status Reference

| Status | Meaning | Action |
|---|---|---|
| `Synced + Healthy` | Git == Cluster, all pods running | ✅ Nothing needed |
| `OutOfSync` | Git != Cluster (drift or new commit) | Auto-heals, or `argocd app sync` |
| `Synced + Degraded` | Applied OK, but pod is crashing | Check pod logs |
| `SyncFailed` | ArgoCD failed to apply (YAML error, RBAC) | Check ArgoCD logs |
| `Unknown` | ArgoCD cannot reach the cluster | Check network/credentials |

```bash
# Check sync status programmatically (for CI health gate)
STATUS=$(argocd app get smartscale-ai -o json | jq -r '.status.sync.status')
HEALTH=$(argocd app get smartscale-ai -o json | jq -r '.status.health.status')
if [[ "$STATUS" == "Synced" && "$HEALTH" == "Healthy" ]]; then
  echo "Deployment successful"
else
  echo "Deployment failed: sync=$STATUS health=$HEALTH"
  exit 1
fi
```
