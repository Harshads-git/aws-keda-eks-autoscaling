# Kustomize Guide: Multi-Environment Configuration Management

This guide explains how Kustomize overlays manage Dev → Staging → Prod
environment differences without duplicating YAML.

---

## 1. Why Kustomize (vs copying YAML per environment)

```
Without Kustomize (naive approach):
  manifests-dev/   ← copy of all YAML with dev settings
  manifests-prod/  ← copy of all YAML with prod settings
  Problem: 2 copies → config drift guaranteed
    Fix a bug in deployment.yaml → must update both copies
    (Usually one copy is forgotten → environments diverge silently)

With Kustomize:
  kustomize/base/           ← ONE canonical copy of all YAML
  kustomize/overlays/dev/   ← ONLY the dev differences (patches)
  kustomize/overlays/prod/  ← ONLY the prod differences (patches)
  Fix a bug in base/deployment.yaml → BOTH environments get the fix
```

---

## 2. Directory Structure

```
kustomize/
├── base/
│   └── kustomization.yaml   ← declares: namespace, labels, resources, images
│
└── overlays/
    ├── dev/
    │   └── kustomization.yaml   ← patches: reduced resources, DEBUG logging
    ├── staging/
    │   └── kustomization.yaml   ← patches: prod-matching limits, INFO logging
    └── prod/
        └── kustomization.yaml   ← patches: full limits, WARNING logging, min=1
```

The base references manifests in `../../manifests/` — the same YAML used by
`kubectl apply -f manifests/` directly. There is no duplication.

---

## 3. Environment Comparison

| Setting | dev | staging | prod |
|---|---|---|---|
| CPU request / limit | 25m / 100m | 100m / 500m | 100m / 500m |
| Memory request / limit | 48Mi / 96Mi | 128Mi / 256Mi | 128Mi / 256Mi |
| `minReplicaCount` | 0 | 0 | **1** (warm pod) |
| `maxReplicaCount` | 3 | 3 | **5** (full scale) |
| `cooldownPeriod` | 15s | 120s | **300s** |
| `pollingInterval` | 10s | 15s | 15s |
| `LOG_LEVEL` | DEBUG | INFO | **WARNING** |
| Image tag | latest | pinned SHA | pinned SHA |
| Spot scheduling | optional | enabled | enabled |
| NetworkPolicy | optional | enabled | enabled |
| PDB | optional | enabled | enabled |

---

## 4. Applying an Environment

```bash
# Preview what will change (no cluster modifications)
kubectl diff -k kustomize/overlays/dev/
kubectl diff -k kustomize/overlays/staging/
kubectl diff -k kustomize/overlays/prod/

# Apply an environment
kubectl apply -k kustomize/overlays/dev/
kubectl apply -k kustomize/overlays/staging/
kubectl apply -k kustomize/overlays/prod/

# Use the wrapper script (recommended — handles image tag + safety gate)
bash scripts/deploy-environment.sh dev
bash scripts/deploy-environment.sh staging --image-tag sha-abc1234
bash scripts/deploy-environment.sh prod --dry-run --image-tag sha-abc1234
bash scripts/deploy-environment.sh prod --image-tag sha-abc1234

# Tear down an environment
kubectl delete -k kustomize/overlays/dev/
bash scripts/deploy-environment.sh dev --teardown
```

---

## 5. How Patches Work

A Kustomize **strategic merge patch** only overrides specific fields — everything
else continues to come from the base.

**Example: change only the CPU limit in dev**

```yaml
# overlays/dev/kustomization.yaml patch:
patches:
  - target:
      kind: Deployment
      name: keda-demo
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: keda-demo
      spec:
        template:
          spec:
            containers:
              - name: app
                resources:
                  limits:
                    cpu: "100m"   # ← Only this field is overridden
```

The base Deployment's image, probes, env, volumes, and everything else are
**untouched**. Kustomize merges the patch into the base at render time.

---

## 6. Updating the Image Tag

```bash
# Option A: Edit kustomization.yaml directly
cd kustomize/overlays/prod
kustomize edit set image keda-demo-app=183264980.dkr.ecr.us-east-1.amazonaws.com/keda-demo-app:sha-abc1234
kubectl apply -k .

# Option B: Pass tag through the deploy script (does NOT modify the file)
bash scripts/deploy-environment.sh prod --image-tag sha-abc1234

# Option C: CD pipeline (cd.yml) — automated on every merge to main
# The workflow reads ECR_REPO_URI and IMAGE_SHA from GitHub environment variables
# and passes them to helm upgrade --set image.tag=... or kustomize edit set image
```

---

## 7. Environment Promotion Workflow

```
Developer opens PR → CI runs (lint, test, docker build)
       │
       ▼ PR merged to main
GitHub Actions CD pipeline:
  1. Build Docker image → push to ECR → tag: sha-<commit>
  2. Deploy to dev:
       bash scripts/deploy-environment.sh dev \
         --tool helm --image-tag sha-<commit>
  3. Run integration smoke test (scripts/run-e2e-test.sh)
  4. If tests pass → Deploy to staging:
       bash scripts/deploy-environment.sh staging \
         --tool helm --image-tag sha-<commit>
  5. Manual approval (GitHub Actions environment protection rule)
  6. Deploy to prod:
       bash scripts/deploy-environment.sh prod \
         --tool helm --image-tag sha-<commit>
```

---

## 8. Kustomize vs Helm: When to Use Which

Both tools are available for this project. Use the right one for each task:

| Scenario | Use |
|---|---|
| Quick dev iteration, simple patches | `kubectl apply -k overlays/dev/` |
| CI/CD deployment with secrets from env vars | `helm upgrade --install -f values-prod.yaml` |
| Diff before applying | `kubectl diff -k overlays/prod/` |
| View final rendered YAML | `kubectl kustomize overlays/prod/` or `helm template` |
| Rollback | `helm rollback keda-demo` (Helm tracks history; Kustomize doesn't) |
| Adding a completely new resource | Edit `base/kustomization.yaml` resources list |

The key difference: **Helm tracks release history and supports rollback**.
Kustomize is stateless — rollback requires applying the previous overlay state.
For production, the CD pipeline uses Helm with `--atomic` to auto-rollback
on failed deployments.
