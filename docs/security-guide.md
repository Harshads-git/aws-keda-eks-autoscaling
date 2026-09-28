# Security Guide — SmartScale AI

Vulnerability management, CVE triage process, and security scanning integration
for the SmartScale AI AWS KEDA EKS autoscaling project.

---

## 1. Security Scanning Overview

SmartScale AI uses **Trivy** (Aqua Security) for continuous vulnerability scanning:

| Scan Target | Tool | Trigger | Blocks PR? |
|---|---|---|---|
| Docker image (OS + pip) | Trivy image | Every push, weekly | YES — HIGH/CRITICAL |
| Python requirements.txt | Trivy fs | Every push | YES — HIGH/CRITICAL |
| Dockerfile misconfigs | Trivy fs --misconfig | Every push | YES — HIGH/CRITICAL |
| Secrets in code | Trivy fs --secret | Every push | YES — HIGH/CRITICAL |
| K8s manifest misconfigs | Trivy config | Every push | NO — Informational |
| Terraform IaC | Trivy config (future) | Future | — |

**GitHub Security tab:** All scan results are uploaded as SARIF reports, viewable at:
`https://github.com/Harshads-git/aws-keda-eks-autoscaling/security/code-scanning`

---

## 2. Running Scans Locally

Always scan locally **before pushing** to catch CVEs early:

```bash
# Full scan (image + filesystem + K8s configs)
./scripts/trivy-scan.sh

# Image scan only (quickest check after Dockerfile changes)
./scripts/trivy-scan.sh image

# Filesystem only (after requirements.txt changes)
./scripts/trivy-scan.sh fs

# All severities (for full review, not just blocking ones)
./scripts/trivy-scan.sh --all-sev
```

### One-liner scan without the script

```bash
# Scan Docker image directly
trivy image --severity HIGH,CRITICAL --ignore-unfixed keda-demo-app:latest

# Scan Python requirements
trivy fs --severity HIGH,CRITICAL --scanners vuln application/requirements.txt

# Check for secrets in entire repo
trivy fs --scanners secret .
```

---

## 3. CVE Triage Process

When Trivy reports a vulnerability, follow this decision tree:

```
CVE Found
    │
    Is it in a package we directly import?
    │
    YES → Check if a fixed version exists
    │       Fixed version available → UPDATE requirements.txt
    │       No fix yet (ignore-unfixed) → SKIP (CI already ignores unfixed)
    │
    NO  → Transitive dependency
            Can we pin the fixed transitive? → ADD to requirements.txt
            No fix in dep tree → ACCEPT + document in .trivyignore

Severity?
    CRITICAL → Fix immediately (block release)
    HIGH     → Fix before next sprint
    MEDIUM   → Fix within 30 days
    LOW      → Fix opportunistically (next requirements.txt update)
```

### Accepting a known false-positive

Create `.trivyignore` at the repo root:

```
# .trivyignore — Known acceptable false positives
# Format: CVE-ID [space] # Justification

# Example: CVE-2023-12345 is in the 'dev' extra of urllib3 which we don't use.
# Tracking: https://github.com/Harshads-git/aws-keda-eks-autoscaling/issues/42
CVE-2023-12345

# Example: Pillow CVE only affects image processing; we don't process images.
CVE-2023-67890
```

---

## 4. Fixing Vulnerable Python Packages

### Step 1: Identify the CVE

```bash
# Get JSON output with full CVE details
trivy fs --format json --scanners vuln application/requirements.txt \
  | jq '.Results[].Vulnerabilities[] | {pkg: .PkgName, id: .VulnerabilityID, severity: .Severity, fix: .FixedVersion}'
```

### Step 2: Update requirements.txt

```
# Before (vulnerable):
boto3==1.26.0

# After (patched):
boto3==1.34.0   # Fixed CVE-2023-XXXXX (SSRF in presigned URL handling)
```

### Step 3: Verify fix with pip-audit

```bash
pip install pip-audit
pip-audit -r application/requirements.txt
```

### Step 4: Re-run Trivy

```bash
./scripts/trivy-scan.sh fs
```

---

## 5. Kubernetes Manifest Security Best Practices

Trivy's `config` scan checks for these Kubernetes security misconfigurations:

| Check | Rule | Fix |
|---|---|---|
| Running as root | `KSV020` | Add `runAsNonRoot: true` to `securityContext` |
| Writable root filesystem | `KSV014` | Add `readOnlyRootFilesystem: true` |
| Missing securityContext | `KSV030` | Add `securityContext: {}` block |
| Privileged container | `KSV017` | Remove `privileged: true` |
| Missing resource limits | `KSV011` | Add `resources.limits.cpu/memory` |
| Allow privilege escalation | `KSV001` | Add `allowPrivilegeEscalation: false` |

### Recommended securityContext for production

```yaml
# Add to each container spec in production (not local demo)
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

> **Note:** The local demo manifests (keda-demo-app) intentionally omit some of
> these settings for simplicity. The Trivy config scan is set to `exit-code: 0`
> (informational only) for this reason.

---

## 6. Secret Detection

Trivy's `--scanners secret` check prevents accidentally committed credentials.

**What it detects:**
- AWS Access Keys (`AKIA...`)
- GitHub Personal Access Tokens (`ghp_...`)
- Private RSA keys
- Slack webhook URLs
- Generic high-entropy strings in `.env` files

**If a secret is found:**
1. **Revoke the secret immediately** (AWS Console > IAM > Delete access key)
2. Remove from codebase with `git filter-repo` (not just `git rm`)
3. Rotate all potentially-exposed secrets
4. Add pattern to `.trivyignore` only after confirming it is a test credential

---

## 7. Security Scanning in the CI Pipeline

The `security-scan.yml` workflow runs on every push to `main` and every PR:

```
Push/PR → security-scan.yml
              │
              ├── trivy-image-scan (Job 1)
              │     Build image → Scan OS+pip → SARIF upload
              │     EXIT 1 on HIGH/CRITICAL → PR blocked
              │
              ├── trivy-filesystem-scan (Job 2)
              │     Scan requirements.txt + Dockerfile + secrets → SARIF upload
              │     EXIT 1 on HIGH/CRITICAL → PR blocked
              │
              └── trivy-config-scan (Job 3)
                    Scan manifests/ for K8s misconfigs → SARIF upload
                    EXIT 0 always (informational)
```

**Weekly schedule:** Runs every Monday 06:00 UTC to catch newly published CVEs
even when no code changes have been made.

---

## 8. Security Metrics to Track

Monitor these in the GitHub Security tab over time:

| Metric | Target | Action if exceeded |
|---|---|---|
| Open CRITICAL CVEs | 0 | Fix immediately, block release |
| Open HIGH CVEs | Less than 3 | Fix within current sprint |
| Mean time to fix HIGH | Less than 7 days | Review triage process |
| False positives in `.trivyignore` | Less than 10 | Audit quarterly |
