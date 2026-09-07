# Helm Guide: Installing and Managing keda-demo

This guide covers the complete lifecycle of the `keda-demo` Helm chart:
install, upgrade, rollback, test, and debug.

---

## 1. Prerequisites

```bash
# Install Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version   # Helm v3.x.x

# Cluster must be configured (EKS, KEDA installed)
kubectl config current-context   # → arn:aws:eks:us-east-1:...:cluster/keda-demo-dev
```

**Required before install** (from `terraform output`):

```bash
# Get required values from Terraform
cd terraform
terraform output sqs_queue_url        # → aws.sqsQueueUrl
terraform output consumer_role_arn    # → aws.irsaRoleArn
terraform output ecr_repository_url   # → image.repository
```

---

## 2. Install

```bash
# Full install — all 3 required values set at command line
helm install keda-demo ./helm/keda-demo \
  --namespace keda-demo \
  --create-namespace \
  --set image.repository=183264980.dkr.ecr.us-east-1.amazonaws.com/keda-demo-app \
  --set image.tag=latest \
  --set aws.sqsQueueUrl=https://sqs.us-east-1.amazonaws.com/183264980/keda-demo-queue \
  --set aws.irsaRoleArn=arn:aws:iam::183264980:role/keda-demo-dev-consumer-role

# Verify installation
helm status keda-demo
helm list -n keda-demo

# Check all resources created
kubectl get all -n keda-demo
kubectl get scaledobject,triggerauth -n keda-demo
kubectl get pdb,networkpolicy,resourcequota -n keda-demo
```

### Install with Spot nodes enabled

```bash
helm install keda-demo ./helm/keda-demo \
  --set image.repository=... \
  --set aws.sqsQueueUrl=... \
  --set aws.irsaRoleArn=... \
  --set spot.enabled=true
```

### Install with monitoring disabled (minimal, t3.micro)

```bash
helm install keda-demo ./helm/keda-demo \
  --set image.repository=... \
  --set aws.sqsQueueUrl=... \
  --set aws.irsaRoleArn=... \
  --set metricsService.enabled=false \
  --set networkPolicy.enabled=false
```

---

## 3. Upgrade

### Upgrade image tag (the most common operation)

```bash
# Roll out a new image version
helm upgrade keda-demo ./helm/keda-demo \
  --set image.tag=sha-abc1234 \
  --reuse-values   # Keep all other values unchanged

# Watch rollout progress
kubectl rollout status deployment/keda-demo -n keda-demo
```

### How `--reuse-values` works

```
helm install: values.yaml + --set flags → release secret stored in K8s
helm upgrade --reuse-values: takes stored values + applies new --set on top

WITHOUT --reuse-values: Helm resets to values.yaml defaults
  (e.g. image.tag reverts to 'latest' — usually wrong in production)
WITH --reuse-values: previous overrides preserved, only new --set applied
```

### Upgrade KEDA scaling parameters

```bash
helm upgrade keda-demo ./helm/keda-demo \
  --set keda.maxReplicaCount=10 \
  --set keda.targetQueueLength=3 \
  --reuse-values
```

### Upgrade with a values file (recommended for environments)

```bash
# Create environment-specific overrides
cat > helm/keda-demo/values-prod.yaml << 'EOF'
keda:
  maxReplicaCount: 20
  targetQueueLength: 3
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
spot:
  enabled: true
EOF

helm upgrade keda-demo ./helm/keda-demo \
  -f helm/keda-demo/values-prod.yaml \
  --set image.tag=sha-abc1234 \
  --reuse-values
```

---

## 4. Rollback

```bash
# View release history
helm history keda-demo -n keda-demo
# REVISION  STATUS     CHART              APP VERSION  DESCRIPTION
# 1         deployed   keda-demo-0.1.0   1.0.0        Install complete
# 2         deployed   keda-demo-0.1.0   1.0.0        Upgrade complete
# 3         failed     keda-demo-0.1.0   1.0.0        Upgrade "keda-demo" failed

# Roll back to previous revision
helm rollback keda-demo

# Roll back to specific revision
helm rollback keda-demo 1

# Verify rollback
kubectl rollout status deployment/keda-demo -n keda-demo
```

### What rollback actually does

```
Helm rollback to revision N:
  1. Renders the chart with revision N's values
  2. Applies the rendered manifests (kubectl apply equivalent)
  3. Deployment controller starts rolling update to old image
  4. Pod by pod: new pod (old image) comes up, old pod (new image) terminates
  5. Deployment returns to old state
  6. Helm marks new revision as DEPLOYED (rollback IS a new revision)
```

---

## 5. Template Rendering (dry-run + debug)

```bash
# Render templates without applying (check YAML output)
helm template keda-demo ./helm/keda-demo \
  --set image.repository=myrepo/app \
  --set image.tag=v1.0.0 \
  --set aws.sqsQueueUrl=https://sqs.us-east-1.amazonaws.com/123/queue \
  --set aws.irsaRoleArn=arn:aws:iam::123:role/role

# Dry-run against cluster (validates against cluster API)
helm install keda-demo ./helm/keda-demo \
  --dry-run \
  --set image.repository=myrepo/app \
  --set aws.sqsQueueUrl=... \
  --set aws.irsaRoleArn=...

# Lint the chart (check for common issues)
helm lint ./helm/keda-demo \
  --set image.repository=myrepo/app \
  --set aws.sqsQueueUrl=https://example.com/queue \
  --set aws.irsaRoleArn=arn:aws:iam::123:role/role
# → [INFO] Chart.yaml: icon is recommended
# → 1 chart(s) linted, 0 chart(s) failed
```

---

## 6. Helm vs Raw `kubectl apply`

| Capability | `kubectl apply` | `helm install/upgrade` |
|---|---|---|
| **Parameterization** | `envsubst` hack | Native `{{ .Values.x }}` |
| **Versioning** | Git only | Helm release history |
| **Rollback** | Manual `git revert` + apply | `helm rollback` (seconds) |
| **Dry-run** | `kubectl --dry-run=client` | `helm template` + `--dry-run` |
| **Lifecycle hooks** | None | pre-install, post-upgrade, etc. |
| **Package distribution** | Git clone | `helm repo add` + `helm pull` |
| **Secrets** | Manual base64 | Helm secrets plugins |
| **Conditional resources** | Multiple overlays | `{{- if .Values.x }}` |

---

## 7. Common Commands Reference

```bash
# Installation
helm install   keda-demo ./helm/keda-demo --set image.repository=...
helm upgrade   keda-demo ./helm/keda-demo --set image.tag=sha-xyz --reuse-values
helm rollback  keda-demo [revision]
helm uninstall keda-demo -n keda-demo

# Inspection
helm list -n keda-demo                  # Show all releases
helm status keda-demo -n keda-demo      # Release status + NOTES.txt
helm history keda-demo -n keda-demo     # Revision history
helm get values keda-demo -n keda-demo  # Show currently applied values
helm get manifest keda-demo             # Show rendered YAML currently deployed

# Validation
helm lint ./helm/keda-demo --set image.repository=test --set aws.sqsQueueUrl=test --set aws.irsaRoleArn=test
helm template keda-demo ./helm/keda-demo --set ...  # Render without applying
helm diff upgrade keda-demo ./helm/keda-demo ...    # (requires helm-diff plugin)
```

---

## 8. CI/CD Integration (`--atomic` pattern)

In the CD pipeline (`.github/workflows/cd.yml`), use `--atomic` for safe upgrades:

```bash
helm upgrade --install keda-demo ./helm/keda-demo \
  --atomic \              # If upgrade fails: auto-rollback to previous release
  --timeout 5m \          # Wait up to 5 minutes for rollout to complete
  --set image.tag=${IMAGE_TAG} \
  --set aws.sqsQueueUrl=${SQS_QUEUE_URL} \
  --set aws.irsaRoleArn=${CONSUMER_ROLE_ARN} \
  --set image.repository=${ECR_REPO_URI} \
  --wait                  # Wait for all pods to be Ready before marking success
```

`--atomic` means: if the rollout doesn't complete in `--timeout`, Helm
automatically rolls back to the previous successful release. This prevents
broken deployments from staying in the cluster.
