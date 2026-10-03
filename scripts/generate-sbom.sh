#!/usr/bin/env bash
# =============================================================================
# scripts/generate-sbom.sh — Local SBOM Generation
# =============================================================================
# Generates a Software Bill of Materials (SBOM) locally using Anchore Syft.
# Mirrors the CI workflow in .github/workflows/sbom.yml.
#
# Usage:
#   ./scripts/generate-sbom.sh                  # Image SBOM (SPDX + CycloneDX)
#   ./scripts/generate-sbom.sh app              # Application directory only
#   ./scripts/generate-sbom.sh image            # Docker image only
#   ./scripts/generate-sbom.sh --format spdx    # Specific format
#   ./scripts/generate-sbom.sh --format cyclonedx
#   ./scripts/generate-sbom.sh --scan           # Also run Grype after generation
#
# Prerequisites:
#   Syft:  curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
#   Grype: curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin
#   Docker (for image scan)
#
# Output:
#   sbom/sbom-image-spdx.json      — Image SBOM in SPDX format
#   sbom/sbom-image-cyclonedx.json — Image SBOM in CycloneDX format
#   sbom/sbom-app-spdx.json        — App directory SBOM
#   sbom/grype-results.json        — Grype vulnerability report (with --scan)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/sbom"
IMAGE_NAME="keda-demo-app:sbom"
SCAN_MODE="all"
FORMAT="both"
RUN_GRYPE=false

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[PASS]${NC} $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; echo -e "${BOLD}$*${NC}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    app|image|all)    SCAN_MODE="$1" ;;
    --format)         FORMAT="$2"; shift ;;
    --scan)           RUN_GRYPE=true ;;
    --help|-h)
      grep "^#" "$0" | head -25 | sed 's/^# \{0,2\}//'
      exit 0
      ;;
    *) warning "Unknown argument: $1" ;;
  esac
  shift
done

# ── Preflight ──────────────────────────────────────────────────────────────────
preflight() {
  header "SmartScale AI — SBOM Generation"

  if ! command -v syft &>/dev/null; then
    error "Syft not installed.\n  Install: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin"
  fi

  SYFT_VERSION=$(syft version 2>&1 | grep -oP 'Version:\s*\K[^\s]+' || echo "unknown")
  info "Syft version: $SYFT_VERSION"

  if $RUN_GRYPE && ! command -v grype &>/dev/null; then
    warning "Grype not installed — skipping vulnerability scan.\n  Install: curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin"
    RUN_GRYPE=false
  fi

  mkdir -p "$OUTPUT_DIR"
  info "Output directory: $OUTPUT_DIR"
}

# ── Generate image SBOM ────────────────────────────────────────────────────────
generate_image_sbom() {
  header "Generating Docker Image SBOM"

  if ! docker info &>/dev/null 2>&1; then
    error "Docker is not running."
  fi

  info "Building Docker image: $IMAGE_NAME"
  docker build -t "$IMAGE_NAME" "$REPO_ROOT/application" --quiet
  success "Image built"

  if [[ "$FORMAT" == "spdx" || "$FORMAT" == "both" ]]; then
    info "Generating SPDX SBOM..."
    syft "$IMAGE_NAME" \
      --output "spdx-json=$OUTPUT_DIR/sbom-image-spdx.json" \
      --quiet
    success "SPDX SBOM: $OUTPUT_DIR/sbom-image-spdx.json"
    print_spdx_summary "$OUTPUT_DIR/sbom-image-spdx.json"
  fi

  if [[ "$FORMAT" == "cyclonedx" || "$FORMAT" == "both" ]]; then
    info "Generating CycloneDX SBOM..."
    syft "$IMAGE_NAME" \
      --output "cyclonedx-json=$OUTPUT_DIR/sbom-image-cyclonedx.json" \
      --quiet
    success "CycloneDX SBOM: $OUTPUT_DIR/sbom-image-cyclonedx.json"
  fi

  if $RUN_GRYPE; then
    run_grype "$OUTPUT_DIR/sbom-image-spdx.json" "image"
  fi
}

# ── Generate application directory SBOM ───────────────────────────────────────
generate_app_sbom() {
  header "Generating Application Directory SBOM"

  info "Scanning: $REPO_ROOT/application"
  syft "dir:$REPO_ROOT/application" \
    --output "spdx-json=$OUTPUT_DIR/sbom-app-spdx.json" \
    --quiet
  success "App SBOM: $OUTPUT_DIR/sbom-app-spdx.json"

  print_spdx_summary "$OUTPUT_DIR/sbom-app-spdx.json"
  print_license_summary "$OUTPUT_DIR/sbom-app-spdx.json"

  if $RUN_GRYPE; then
    run_grype "$OUTPUT_DIR/sbom-app-spdx.json" "app"
  fi
}

# ── Grype vulnerability scan on SBOM ──────────────────────────────────────────
run_grype() {
  local sbom_file="$1"
  local label="$2"

  header "Grype Vulnerability Scan ($label)"
  info "Scanning SBOM for vulnerabilities..."

  set +e
  grype "sbom:$sbom_file" \
    --output json \
    --file "$OUTPUT_DIR/grype-${label}-results.json" \
    --fail-on high \
    --quiet
  GRYPE_EXIT=$?
  set -e

  # Print human-readable summary
  grype "sbom:$sbom_file" --output table 2>/dev/null || true

  if [ $GRYPE_EXIT -eq 0 ]; then
    success "Grype scan PASSED — no HIGH/CRITICAL vulnerabilities"
  else
    warning "Grype scan found HIGH/CRITICAL vulnerabilities"
    echo "  Full report: $OUTPUT_DIR/grype-${label}-results.json"
    echo "  Tip: Update versions in application/requirements.txt"
  fi
}

# ── Pretty-print SPDX summary ─────────────────────────────────────────────────
print_spdx_summary() {
  local file="$1"
  python3 -c "
import json, sys
data = json.load(open('$file'))
pkgs = data.get('packages', [])
total = len(pkgs)
# Count by primary package purpose
purposes = {}
for p in pkgs:
    pur = p.get('primaryPackagePurpose', 'OTHER')
    purposes[pur] = purposes.get(pur, 0) + 1
print(f'  Total packages: {total}')
for pur, count in sorted(purposes.items(), key=lambda x: -x[1])[:5]:
    print(f'    {pur}: {count}')
" 2>/dev/null || info "Install python3 for SBOM summary"
}

# ── License summary ───────────────────────────────────────────────────────────
print_license_summary() {
  local file="$1"
  echo ""
  info "License breakdown:"
  python3 -c "
import json
data = json.load(open('$file'))
licenses = {}
for pkg in data.get('packages', []):
    lic = pkg.get('licenseConcluded', 'NOASSERTION')
    for l in lic.split(' AND '):
        l = l.strip()
        if l and l not in ('NOASSERTION', 'NONE'):
            licenses[l] = licenses.get(l, 0) + 1
for lic, count in sorted(licenses.items(), key=lambda x: -x[1]):
    # Flag potential GPL issues
    flag = '⚠️ ' if 'GPL' in lic and 'LGPL' not in lic else '  '
    print(f'  {flag}{lic}: {count}')
" 2>/dev/null || true
}

# ── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
  header "SBOM Generation Summary"
  echo ""
  for f in "$OUTPUT_DIR"/*.json; do
    [ -f "$f" ] && echo -e "  ${GREEN}✅${NC} $(basename $f) ($(du -sh $f | cut -f1))"
  done
  echo ""
  echo "  View SPDX SBOM online: https://spdx.github.io/spdx-spec/"
  echo "  Import CycloneDX to:   https://owasp.org/www-project-dependency-track/"
  echo ""
  success "SBOM generation complete"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  preflight

  case "$SCAN_MODE" in
    image) generate_image_sbom ;;
    app)   generate_app_sbom ;;
    all)
      generate_image_sbom
      generate_app_sbom
      ;;
  esac

  print_summary
}

main "$@"
