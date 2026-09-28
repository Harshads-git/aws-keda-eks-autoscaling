#!/usr/bin/env bash
# =============================================================================
# scripts/trivy-scan.sh — Local Trivy Security Scan
# =============================================================================
# Runs Trivy security scans locally (before pushing to GitHub).
# Mirrors the three scans in .github/workflows/security-scan.yml.
#
# Usage:
#   ./scripts/trivy-scan.sh               # All scans (image + fs + config)
#   ./scripts/trivy-scan.sh image         # Docker image scan only
#   ./scripts/trivy-scan.sh fs            # Filesystem scan only
#   ./scripts/trivy-scan.sh config        # K8s manifest scan only
#   ./scripts/trivy-scan.sh --critical    # Only show CRITICAL (not HIGH)
#   ./scripts/trivy-scan.sh --all-sev     # Show all severities (verbose)
#
# Prerequisites:
#   Trivy installed: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
#     macOS: brew install trivy
#     Linux: sudo snap install trivy
#     Windows (WSL): curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh
#   Docker running (for image scan)
#
# Exit codes:
#   0 — No HIGH/CRITICAL vulnerabilities found
#   1 — HIGH/CRITICAL vulnerabilities found (fix before pushing)
#   2 — Trivy not installed
#   3 — Docker not running (for image scan)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="keda-demo-app:scan"
SEVERITY="HIGH,CRITICAL"
SCAN_TYPE="all"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'  # No Colour

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[PASS]${NC} $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
header()  { echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════${NC}"; echo -e "${BOLD}$*${NC}"; echo -e "${BOLD}${BLUE}═══════════════════════════════════════${NC}"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    image|fs|config|all) SCAN_TYPE="$arg" ;;
    --critical)  SEVERITY="CRITICAL" ;;
    --all-sev)   SEVERITY="LOW,MEDIUM,HIGH,CRITICAL" ;;
    --help|-h)
      grep "^#" "$0" | head -30 | sed 's/^# \{0,2\}//'
      exit 0
      ;;
    *) warning "Unknown argument: $arg (ignored)" ;;
  esac
done

# ── Preflight checks ───────────────────────────────────────────────────────────
preflight() {
  header "SmartScale AI — Trivy Security Scan"
  info "Repo root: $REPO_ROOT"
  info "Severity filter: $SEVERITY"
  info "Scan type: $SCAN_TYPE"

  if ! command -v trivy &>/dev/null; then
    error "Trivy is not installed."
    echo "  Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
    echo "  Quick (Linux/macOS): curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin"
    exit 2
  fi

  TRIVY_VERSION=$(trivy --version 2>&1 | head -1)
  info "Trivy version: $TRIVY_VERSION"

  # Update Trivy DB to get latest CVEs
  info "Updating Trivy vulnerability database..."
  trivy image --download-db-only --quiet 2>/dev/null || \
    warning "DB update failed (offline mode — using cached DB)"
}

# ── Scan functions ─────────────────────────────────────────────────────────────

scan_image() {
  header "Scan 1/3: Docker Image — $IMAGE_NAME"

  if ! docker info &>/dev/null 2>&1; then
    error "Docker is not running. Start Docker Desktop and retry."
    return 3
  fi

  info "Building Docker image for scanning..."
  if docker build -t "$IMAGE_NAME" "$REPO_ROOT/application" --quiet; then
    success "Image built: $IMAGE_NAME"
  else
    error "Docker build failed — cannot scan image"
    return 1
  fi

  info "Scanning image for OS and Python package vulnerabilities..."
  set +e
  trivy image \
    --severity "$SEVERITY" \
    --exit-code 1 \
    --ignore-unfixed \
    --vuln-type "os,library" \
    --format table \
    "$IMAGE_NAME"
  IMAGE_EXIT=$?
  set -e

  if [ $IMAGE_EXIT -eq 0 ]; then
    success "Image scan PASSED — no $SEVERITY vulnerabilities found"
  else
    error "Image scan FAILED — $SEVERITY vulnerabilities found"
    echo "  Action: update pinned package versions in application/requirements.txt"
    echo "  Tip:    trivy image --severity $SEVERITY --format json $IMAGE_NAME | jq '.Results[].Vulnerabilities[]'"
  fi

  return $IMAGE_EXIT
}

scan_filesystem() {
  header "Scan 2/3: Filesystem (requirements.txt + Dockerfile + secrets)"

  info "Scanning repository filesystem..."
  set +e
  trivy fs \
    --severity "$SEVERITY" \
    --exit-code 1 \
    --ignore-unfixed \
    --scanners vuln,misconfig,secret \
    --format table \
    "$REPO_ROOT"
  FS_EXIT=$?
  set -e

  if [ $FS_EXIT -eq 0 ]; then
    success "Filesystem scan PASSED — no $SEVERITY issues found"
  else
    error "Filesystem scan FAILED"
    echo "  Vulnerabilities: check requirements.txt for outdated packages"
    echo "  Misconfigs:      check Dockerfile (running as root, etc.)"
    echo "  Secrets:         check for accidentally committed credentials"
  fi

  return $FS_EXIT
}

scan_config() {
  header "Scan 3/3: Kubernetes Manifests (IaC Misconfiguration)"

  info "Scanning manifests/ for Kubernetes security misconfigurations..."
  set +e
  trivy config \
    --severity "$SEVERITY" \
    --exit-code 0 \
    --scanners misconfig \
    --format table \
    "$REPO_ROOT/manifests"
  CONFIG_EXIT=$?
  set -e

  # Config scan is informational (exit 0 regardless of findings)
  if [ $CONFIG_EXIT -eq 0 ]; then
    success "Config scan complete — review any findings above"
  else
    warning "Config scan found misconfigurations (informational, not blocking)"
    echo "  Common findings for local-demo manifests:"
    echo "    KSV014: Use read-only root filesystem → add readOnlyRootFilesystem: true"
    echo "    KSV020: Runs as root → add runAsNonRoot: true to securityContext"
    echo "    KSV030: Missing securityContext → add securityContext block"
  fi

  return 0  # Always pass config scan
}

# ── Summary ────────────────────────────────────────────────────────────────────

print_summary() {
  local img_result=$1 fs_result=$2

  header "Scan Summary"
  echo ""

  if [ "${SCAN_TYPE}" = "all" ] || [ "${SCAN_TYPE}" = "image" ]; then
    if [ "$img_result" -eq 0 ]; then
      echo -e "  Docker image:     ${GREEN}✅ PASS${NC}"
    else
      echo -e "  Docker image:     ${RED}❌ FAIL${NC}  (${SEVERITY} CVEs found)"
    fi
  fi

  if [ "${SCAN_TYPE}" = "all" ] || [ "${SCAN_TYPE}" = "fs" ]; then
    if [ "$fs_result" -eq 0 ]; then
      echo -e "  Filesystem:       ${GREEN}✅ PASS${NC}"
    else
      echo -e "  Filesystem:       ${RED}❌ FAIL${NC}  (${SEVERITY} issues found)"
    fi
  fi

  if [ "${SCAN_TYPE}" = "all" ] || [ "${SCAN_TYPE}" = "config" ]; then
    echo -e "  K8s manifests:    ${YELLOW}ℹ INFO${NC}  (review output above)"
  fi

  echo ""
  if [ "$img_result" -ne 0 ] || [ "$fs_result" -ne 0 ]; then
    error "One or more blocking scans failed. Fix vulnerabilities before pushing."
    echo ""
    echo "  Quick fix guide:"
    echo "    1. pip-audit to check Python deps:   pip install pip-audit && pip-audit"
    echo "    2. Pin safe versions in requirements.txt"
    echo "    3. Re-run: ./scripts/trivy-scan.sh"
    return 1
  else
    success "All scans passed! Safe to push."
    return 0
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  preflight

  IMG_EXIT=0
  FS_EXIT=0

  case "$SCAN_TYPE" in
    image)
      scan_image || IMG_EXIT=$?
      print_summary $IMG_EXIT 0
      ;;
    fs)
      scan_filesystem || FS_EXIT=$?
      print_summary 0 $FS_EXIT
      ;;
    config)
      scan_config
      ;;
    all)
      scan_image  || IMG_EXIT=$?
      scan_filesystem || FS_EXIT=$?
      scan_config
      print_summary $IMG_EXIT $FS_EXIT
      ;;
  esac
}

main "$@"
