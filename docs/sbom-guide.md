# SBOM & Supply Chain Security Guide

Software Bill of Materials generation, SLSA provenance, and supply chain
security practices for SmartScale AI.

---

## 1. What is an SBOM?

A **Software Bill of Materials (SBOM)** is a machine-readable inventory of every
component in a software artifact — OS packages, Python pip packages, their exact
versions, licenses, and cryptographic hashes.

Analogy: An SBOM is like a **nutrition label** for software. Just as a nutrition
label tells you every ingredient in packaged food, an SBOM tells you every
dependency in your container image.

### Why SBOMs Matter

| Use Case | Without SBOM | With SBOM |
|---|---|---|
| **CVE impact analysis** | "Grep every repo manually for log4j" (hours/days) | Query SBOM: `Which images contain log4j?` (seconds) |
| **License compliance** | Manual audit of requirements.txt files | Automated license extraction per image |
| **Regulatory compliance** | Cannot prove component inventory | Cryptographically signed attestation |
| **Vendor security review** | Share source code or trust vendor | Share SBOM (no source code exposure) |
| **Incident response** | Unknown blast radius of 0-day | Immediately know all affected images |

### Regulatory Drivers

- **US Executive Order 14028** (May 2021): SBOM required for software sold to US government.
- **EU Cyber Resilience Act** (2024): SBOM required for products with digital elements.
- **NIST SP 800-161**: Supply chain risk management, references SBOM.

---

## 2. SBOM Formats

SmartScale AI generates SBOMs in two formats:

### SPDX (Software Package Data Exchange)
- **Standard:** ISO/IEC 5962:2021
- **Best for:** Legal/compliance, widest tooling support
- **File:** `sbom/sbom-image-spdx.json`
- **Key fields:** `name`, `versionInfo`, `downloadLocation`, `licenseConcluded`, `sha256`

### CycloneDX
- **Standard:** OWASP CycloneDX
- **Best for:** Vulnerability enrichment, Dependency Track integration
- **File:** `sbom/sbom-image-cyclonedx.json`
- **Key fields:** `name`, `version`, `purl` (Package URL), `hashes`, `licenses`

---

## 3. Generating SBOMs

### CI/CD (Automatic)

SBOMs are generated automatically on every push to `main`:

```
Push to main
     │
     ▼ (.github/workflows/sbom.yml)
sbom-image job:
  Build Docker image
  → syft (SPDX) → sbom-image-spdx.json
  → syft (CycloneDX) → sbom-image-cyclonedx.json
  → grype (vulnerability scan from SBOM)
  → Upload all to GitHub Actions artifacts (90 days)

sbom-app job:
  → syft dir:application/ → sbom-app-spdx.json
  → License report printed to CI log

Release event:
  → Attach all SBOMs to GitHub Release assets
```

### Local Generation

```bash
# Install Syft
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
  | sh -s -- -b /usr/local/bin

# Generate image + app SBOMs
./scripts/generate-sbom.sh

# Image only (fastest for post-build check)
./scripts/generate-sbom.sh image

# Include Grype vulnerability scan
./scripts/generate-sbom.sh --scan

# View SBOM
cat sbom/sbom-image-spdx.json | jq '.packages[] | {name: .name, version: .versionInfo, license: .licenseConcluded}' | head -40
```

---

## 4. Querying SBOMs

### Find a Specific Package

```bash
# Is log4j in our image? (should return empty for Python app)
cat sbom/sbom-image-spdx.json | jq '.packages[] | select(.name | test("log4j"; "i"))'

# Find all packages with a specific license
cat sbom/sbom-image-spdx.json | jq '.packages[] | select(.licenseConcluded | test("GPL"; "i")) | .name'

# List all Python packages with versions
cat sbom/sbom-app-spdx.json | jq '.packages[] | {name: .name, version: .versionInfo}' | jq -s 'sort_by(.name)[]'
```

### CVE Impact Analysis

```bash
# When a new CVE is announced (e.g., CVE-2024-XXXXX affects boto3 < 1.34.0):
grype "sbom:sbom/sbom-image-spdx.json" --output table | grep boto3

# Check ALL SBOMs in sbom/ for a specific package
for f in sbom/*.json; do
  echo "=== $f ==="
  grype "sbom:$f" --output table --quiet | grep "boto3" || echo "  (not found)"
done
```

---

## 5. SLSA — Supply Chain Levels for Software Artifacts

**SLSA** (pronounced "salsa") is a security framework defining levels of
supply chain integrity:

| SLSA Level | Requirements | SmartScale AI Status |
|---|---|---|
| **Level 0** | No guarantees | — |
| **Level 1** | Build process is documented, SBOM generated | ✅ Current (CI generates SBOM) |
| **Level 2** | Hosted build service, signed provenance | 🔜 Day 45: cosign attestation |
| **Level 3** | Hardened build, two-party review, hermetic builds | Future |
| **Level 4** | Two-party review on all changes, hermetic | Future |

### Achieving SLSA Level 2

SLSA Level 2 requires **signed build provenance** — a cryptographic statement
that "this image was built by GitHub Actions from commit X at time Y."

```yaml
# Add to .github/workflows/sbom.yml to generate SLSA provenance:
- name: Sign SBOM with cosign (SLSA Level 2)
  uses: sigstore/cosign-installer@v3

- name: Attest SBOM to image
  run: |
    cosign attest \
      --predicate sbom-image-spdx.json \
      --type spdx \
      ghcr.io/harshads-git/keda-demo-app:${{ github.sha }}
  # cosign uses GitHub OIDC token (id-token: write permission)
  # Stores attestation in Rekor transparency log (immutable audit trail)
```

**Verifying the attestation:**
```bash
cosign verify-attestation \
  --type spdx \
  --certificate-identity-regexp "https://github.com/Harshads-git/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/harshads-git/keda-demo-app:latest
```

---

## 6. License Compliance

The SBOM license report (from `generate-sbom.sh`) flags GPL licenses.

### License Risk Levels

| License | Risk | Requirement |
|---|---|---|
| MIT, Apache-2.0, BSD-2-Clause | ✅ Low | Attribution only |
| LGPL-2.1, LGPL-3.0 | ⚠️ Medium | Dynamic linking OK; static link = copyleft |
| GPL-2.0, GPL-3.0 | 🔴 High | Derivative works must be open-source |
| AGPL-3.0 | 🔴 Very High | Network use = copyleft (server apps included) |

### Checking Our License Mix

```bash
# Generate license report
./scripts/generate-sbom.sh app

# Expected output for a typical Python app:
#   MIT: 45 packages
#   Apache-2.0: 12 packages
#   BSD-3-Clause: 8 packages
#   PSF-2.0: 3 packages
#   ISC: 2 packages
#   ⚠️ GPL-2.0: 0 packages   ← should be 0
```

---

## 7. Security Tool Stack Summary

| Layer | Tool | Format | When |
|---|---|---|---|
| Build time — CVEs | Trivy | Table + SARIF | Every push (blocks) |
| Build time — SBOM | Syft | SPDX + CycloneDX | Every push (artifact) |
| Build time — SBOM CVEs | Grype | JSON + Table | Every push (blocks) |
| Deploy time — Policy | OPA Gatekeeper | Kubernetes events | Every kubectl apply |
| Runtime — Syscalls | Falco | JSON alerts | Continuous |
| GitOps — Drift | ArgoCD | Sync events | Every 3 minutes |

All six tools work together to provide **defence-in-depth** from code commit
to running container.
