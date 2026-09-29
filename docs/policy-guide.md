# Policy as Code Guide — OPA Gatekeeper

Enforcing Kubernetes security policies with Open Policy Agent (OPA) Gatekeeper
and the Rego policy language.

---

## 1. What is Policy as Code?

**Policy as Code** treats security and compliance rules as version-controlled code
that is automatically evaluated against every cluster change.

Without Policy as Code:
- Security rules live in runbooks and wikis (often ignored).
- Manual review of YAML manifests is slow and error-prone.
- A single misconfigured manifest can deploy a privileged pod to production.

With OPA Gatekeeper:
- Rules are Rego code, reviewed in PRs like application code.
- Every `kubectl apply` is validated by the admission webhook.
- Non-compliant workloads are blocked (or warned) before they ever run.

---

## 2. OPA Gatekeeper Architecture

```
kubectl apply -f manifest.yaml
         │
         ▼
Kubernetes API Server
         │
         ▼ (admission webhook)
Gatekeeper Admission Controller
         │
         ├── ConstraintTemplate 1: RequireResourceLimits (Rego)
         │         └── Constraint: requireresourcelimits-keda-demo
         │
         ├── ConstraintTemplate 2: RequireNonRoot (Rego)
         │         └── Constraint: requirenonroot-keda-demo
         │
         ▼
   All policies pass? → Pod created ✅
   Any policy fails?  → Pod rejected ❌ (or warned ⚠️)
```

Key concepts:
- **ConstraintTemplate**: Defines the Rego logic (the "rule").
- **Constraint**: Instantiates the template with scope (namespace, kind) and parameters.
- **Enforcement action**: `deny` (hard block), `warn` (allow + warn), `dryrun` (audit only).

---

## 3. Installing OPA Gatekeeper on EKS

```bash
# Install Gatekeeper v3.14 (stable release)
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml

# Verify Gatekeeper is running
kubectl get pods -n gatekeeper-system
# NAME                                             READY   STATUS
# gatekeeper-audit-xxxxxxxxx-xxxxx                 1/1     Running
# gatekeeper-controller-manager-xxxxxxxxx-xxxxx    1/1     Running

# Apply SmartScale AI policies
kubectl apply -f policies/require-resource-limits.yaml
kubectl apply -f policies/require-non-root.yaml
```

---

## 4. Policies in This Project

### Policy 1: Require Resource Limits

**File:** [`policies/require-resource-limits.yaml`](../policies/require-resource-limits.yaml)

| | |
|---|---|
| **Kind** | `RequireResourceLimits` |
| **Scope** | `keda-demo` namespace, `Pod` kind |
| **Action** | `warn` → upgrade to `deny` after compliance audit |
| **Requires** | `resources.limits.cpu` AND `resources.limits.memory` |
| **Rationale** | Limits prevent runaway containers from evicting KEDA-scaled pods |

**Rego logic summary:**
```rego
violation if:
  container has NO cpu limit
  OR container has NO memory limit
  AND container image is NOT in exemptImages list
```

**Check current violations (audit mode):**
```bash
kubectl get requireresourcelimits requireresourcelimits-keda-demo \
  -o jsonpath='{.status.violations}' | jq .
```

---

### Policy 2: Require Non-Root Containers

**File:** [`policies/require-non-root.yaml`](../policies/require-non-root.yaml)

| | |
|---|---|
| **Kind** | `RequireNonRoot` |
| **Scope** | `keda-demo` namespace, `Pod` kind |
| **Action** | `warn` → upgrade to `deny` after Dockerfile updates |
| **Requires** | `runAsNonRoot: true` OR `runAsUser > 0` (pod or container level) |
| **Rationale** | Root containers elevate blast radius of container escapes and IRSA token theft |

**Rego logic summary:**
```rego
violation if:
  container does NOT satisfy ANY of:
    pod-level runAsNonRoot == true
    container-level runAsNonRoot == true
    container-level runAsUser > 0
  AND container image is NOT in exemptImages list
```

---

## 5. Enforcement Mode Adoption Path

Go through these stages for each policy:

```
Stage 1: dryrun
  kubectl patch constraint requireresourcelimits-keda-demo \
    --type merge -p '{"spec":{"enforcementAction":"dryrun"}}'
  → Check: kubectl get constraint -o yaml | grep -A20 'status:'
  → Fix: identify all violating pods, update their manifests

Stage 2: warn
  kubectl patch constraint requireresourcelimits-keda-demo \
    --type merge -p '{"spec":{"enforcementAction":"warn"}}'
  → New pods get a warning in kubectl output but are still created
  → Fix: update all remaining violating pods
  → Monitor: 0 warnings in CI logs = ready to promote

Stage 3: deny (production)
  kubectl patch constraint requireresourcelimits-keda-demo \
    --type merge -p '{"spec":{"enforcementAction":"deny"}}'
  → Non-compliant pods are now REJECTED by the API server
  → Alert: set up monitoring on Gatekeeper's constraint_violations metric
```

---

## 6. Fixing Violations

### Resource Limits Violation

```yaml
# BEFORE (violating):
containers:
  - name: my-app
    image: keda-demo-app:latest
    # No resources block → violation

# AFTER (compliant):
containers:
  - name: my-app
    image: keda-demo-app:latest
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

### Non-Root Violation

```yaml
# BEFORE (violating — implicit root):
containers:
  - name: my-app
    image: keda-demo-app:latest
    # No securityContext → runs as UID 0 (root)

# AFTER (compliant — pod level):
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
  containers:
    - name: my-app
      image: keda-demo-app:latest
```

**Also update the Dockerfile:**
```dockerfile
# Add near bottom of Dockerfile
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser
```

---

## 7. Writing Custom Rego Policies

Template for a new policy:

```rego
package mypolicy

# Main violation rule
violation[{"msg": msg}] {
  # 1. Get the resource being admitted
  container := input.review.object.spec.containers[_]

  # 2. Check your condition
  not has_my_requirement(container)

  # 3. Produce a helpful error message
  msg := sprintf("Container '%v' violates my policy because...", [container.name])
}

# Helper function
has_my_requirement(container) {
  # Return true when the container satisfies the policy
  container.myField == "required-value"
}
```

**Test Rego locally with OPA CLI:**
```bash
# Install OPA: https://www.openpolicyagent.org/docs/latest/#1-download-opa
opa test policies/rego/
opa eval --input test-pod.json --data policies/rego/ 'data.mypolicy.violation'
```

---

## 8. Gatekeeper Metrics (Prometheus)

Gatekeeper exposes metrics on port 8888. Add to your Prometheus scrape config:

```yaml
# monitoring/prometheus-config.yaml
scrape_configs:
  - job_name: gatekeeper
    static_configs:
      - targets: ['gatekeeper-controller-manager.gatekeeper-system:8888']
```

**Key metrics to alert on:**

```promql
# Number of active policy violations (alert if > 0 in production)
gatekeeper_constraint_violations{enforcement_action="deny"} > 0

# Request denial rate (policy is blocking admissions)
rate(gatekeeper_request_count_total{admission_status="deny"}[5m]) > 0

# Audit controller finding new violations
rate(gatekeeper_audit_last_run_time[5m]) == 0  # Alert if audit stops running
```

---

## 9. Policy vs Trivy Comparison

| Concern | Trivy (Day 41) | OPA Gatekeeper (Day 42) |
|---|---|---|
| **What it checks** | Known CVEs in packages | Runtime configuration policy |
| **When it runs** | CI pipeline (build time) | Kubernetes admission (deploy time) |
| **Can it block deploys?** | Yes (CI fails) | Yes (admission denied) |
| **Rego/code required?** | No | Yes |
| **Best for** | Dependency vulnerabilities | Workload configuration rules |
| **Complementary?** | ✅ Yes — use both | ✅ Yes — use both |
