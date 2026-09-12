#!/usr/bin/env bash
# =============================================================================
# scripts/deploy-environment.sh — Multi-Environment Deployment Wrapper
# =============================================================================
# Deploys keda-demo to any environment using either Kustomize or Helm.
#
# Usage:
#   bash scripts/deploy-environment.sh <environment> [options]
#
# Environments:
#   dev       → kustomize/overlays/dev/ (fast, cheap, debug logging)
#   staging   → kustomize/overlays/staging/ (prod-like, lower scale ceiling)
#   prod      → kustomize/overlays/prod/ (full production config)
#
# Options:
#   --tool kustomize   Use kubectl apply -k (default)
#   --tool helm        Use helm upgrade --install with values-<env>.yaml
#   --image-tag <sha>  Override image tag (required for staging + prod)
#   --dry-run          Preview changes without applying (kubectl diff -k)
#   --rollback         Rollback to previous Helm revision (helm only)
#   --teardown         Delete all resources for the environment
#
# Examples:
#   # Deploy dev (Kustomize)
#   bash scripts/deploy-environment.sh dev
#
#   # Deploy staging with specific image SHA
#   bash scripts/deploy-environment.sh staging --image-tag sha-abc1234
#
#   # Dry-run prod to preview changes before applying
#   bash scripts/deploy-environment.sh prod --dry-run --image-tag sha-abc1234
#
#   # Deploy prod using Helm (used by CD pipeline)
#   bash scripts/deploy-environment.sh prod --tool helm --image-tag sha-abc1234
#
#   # Rollback prod Helm release
#   bash scripts/deploy-environment.sh prod --tool helm --rollback
# =============================================================================

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
TOOL="kustomize"
IMAGE_TAG=""
DRY_RUN=false
ROLLBACK=false
TEARDOWN=false
HELM_RELEASE_NAME="keda-demo"

# ─── Parse Arguments ──────────────────────────────────────────────────────────
shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)       TOOL="$2"; shift 2 ;;
    --image-tag)  IMAGE_TAG="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --rollback)   ROLLBACK=true; shift ;;
    --teardown)   TEARDOWN=true; shift ;;
    --help|-h)
      sed -n '/^# Usage/,/^# ====/p' "${BASH_SOURCE[0]}" | head -50
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die()  { echo -e "${RED}✗ ERROR:${NC} $*" >&2; exit 1; }

# ─── Validation ───────────────────────────────────────────────────────────────
[[ -z "${ENVIRONMENT}" ]] && die "Environment required. Usage: $0 <dev|staging|prod>"
[[ "${ENVIRONMENT}" =~ ^(dev|staging|prod)$ ]] || die "Unknown environment: ${ENVIRONMENT}. Must be dev, staging, or prod."
[[ "${TOOL}" =~ ^(kustomize|helm)$ ]] || die "Unknown tool: ${TOOL}. Must be kustomize or helm."

# Image tag required for staging and prod (not dev which uses 'latest')
if [[ "${ENVIRONMENT}" != "dev" && -z "${IMAGE_TAG}" && "${DRY_RUN}" = false && "${ROLLBACK}" = false ]]; then
  die "Image tag required for ${ENVIRONMENT}. Use --image-tag sha-<commit>"
fi

OVERLAY_PATH="${REPO_ROOT}/kustomize/overlays/${ENVIRONMENT}"
HELM_CHART="${REPO_ROOT}/helm/keda-demo"
HELM_VALUES="${HELM_CHART}/values-${ENVIRONMENT}.yaml"

# ─── Environment Summary ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SmartScale AI — Deploy to ${ENVIRONMENT^^}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "  Environment: ${BOLD}${ENVIRONMENT}${NC}"
echo -e "  Tool:        ${TOOL}"
echo -e "  Image Tag:   ${IMAGE_TAG:-latest (dev default)}"
echo -e "  Dry-run:     ${DRY_RUN}"
echo -e "  Rollback:    ${ROLLBACK}"
echo -e "  Teardown:    ${TEARDOWN}"
echo ""

# Production safety gate
if [[ "${ENVIRONMENT}" = "prod" && "${DRY_RUN}" = false && "${TEARDOWN}" = false && "${ROLLBACK}" = false ]]; then
  warn "Deploying to PRODUCTION. You have 10 seconds to cancel (Ctrl+C)."
  sleep 10
  log "Proceeding with production deployment..."
fi

# ─── Kustomize Deploy ─────────────────────────────────────────────────────────
deploy_kustomize() {
  log "Using Kustomize overlay: ${OVERLAY_PATH}"

  if [[ ! -f "${OVERLAY_PATH}/kustomization.yaml" ]]; then
    die "Overlay not found: ${OVERLAY_PATH}/kustomization.yaml"
  fi

  # Update image tag in the overlay (temporary — does not modify the file)
  if [[ -n "${IMAGE_TAG}" ]]; then
    log "Setting image tag: ${IMAGE_TAG}"
    cd "${OVERLAY_PATH}"
    kustomize edit set image "keda-demo-app=REPLACE_WITH_ECR_REPO_URI:${IMAGE_TAG}" 2>/dev/null || true
    cd "${REPO_ROOT}"
  fi

  if [[ "${TEARDOWN}" = true ]]; then
    log "Tearing down ${ENVIRONMENT} environment..."
    kubectl delete -k "${OVERLAY_PATH}" --ignore-not-found
    ok "Teardown complete"
    return
  fi

  if [[ "${DRY_RUN}" = true ]]; then
    log "Dry-run: previewing changes for ${ENVIRONMENT}..."
    echo ""
    kubectl diff -k "${OVERLAY_PATH}" || true
    echo ""
    ok "Dry-run complete — no changes applied"
    return
  fi

  log "Applying Kustomize overlay..."
  kubectl apply -k "${OVERLAY_PATH}"
  log "Waiting for rollout to complete..."
  kubectl rollout status deployment/keda-demo \
    -n keda-demo \
    --timeout=5m
  ok "Deployment to ${ENVIRONMENT} complete!"
}

# ─── Helm Deploy ──────────────────────────────────────────────────────────────
deploy_helm() {
  log "Using Helm chart: ${HELM_CHART}"

  if [[ "${ROLLBACK}" = true ]]; then
    log "Rolling back Helm release ${HELM_RELEASE_NAME}..."
    helm rollback "${HELM_RELEASE_NAME}" -n keda-demo
    ok "Rollback complete"
    helm history "${HELM_RELEASE_NAME}" -n keda-demo | tail -3
    return
  fi

  if [[ "${TEARDOWN}" = true ]]; then
    log "Uninstalling Helm release ${HELM_RELEASE_NAME}..."
    helm uninstall "${HELM_RELEASE_NAME}" -n keda-demo --ignore-not-found
    ok "Helm release uninstalled"
    return
  fi

  # Check required env vars for real deployment
  [[ -z "${SQS_QUEUE_URL:-}" ]] && die "SQS_QUEUE_URL environment variable not set"
  [[ -z "${CONSUMER_ROLE_ARN:-}" ]] && die "CONSUMER_ROLE_ARN environment variable not set"
  [[ -z "${ECR_REPO_URI:-}" ]] && die "ECR_REPO_URI environment variable not set"

  local helm_args=(
    upgrade --install "${HELM_RELEASE_NAME}"
    "${HELM_CHART}"
    --namespace keda-demo
    --create-namespace
    --set "image.repository=${ECR_REPO_URI}"
    --set "image.tag=${IMAGE_TAG:-latest}"
    --set "aws.sqsQueueUrl=${SQS_QUEUE_URL}"
    --set "aws.irsaRoleArn=${CONSUMER_ROLE_ARN}"
    --wait
    --timeout 5m
  )

  # Layer in environment-specific values file
  if [[ -f "${HELM_VALUES}" ]]; then
    helm_args+=(-f "${HELM_VALUES}")
    log "Using values file: helm/keda-demo/values-${ENVIRONMENT}.yaml"
  fi

  if [[ "${DRY_RUN}" = true ]]; then
    log "Dry-run Helm upgrade..."
    helm "${helm_args[@]}" --dry-run
    ok "Helm dry-run complete — no changes applied"
    return
  fi

  # --atomic: auto-rollback if upgrade fails within --timeout
  helm_args+=(--atomic)
  log "Running helm upgrade --install --atomic..."
  helm "${helm_args[@]}"
  ok "Helm deployment to ${ENVIRONMENT} complete!"
  helm status "${HELM_RELEASE_NAME}" -n keda-demo
}

# ─── Post-Deploy Verification ─────────────────────────────────────────────────
post_deploy_verify() {
  if [[ "${DRY_RUN}" = true || "${TEARDOWN}" = true || "${ROLLBACK}" = true ]]; then
    return
  fi

  log "Post-deploy verification..."
  echo ""
  kubectl get pods -n keda-demo -l app.kubernetes.io/name=keda-demo
  echo ""
  kubectl get scaledobject -n keda-demo 2>/dev/null || true
  echo ""
  log "Useful commands:"
  echo "  kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=20 --follow"
  echo "  kubectl get hpa -n keda-demo"
  echo "  kubectl top pods -n keda-demo"
}

# ─── Run ──────────────────────────────────────────────────────────────────────
case "${TOOL}" in
  kustomize) deploy_kustomize ;;
  helm)      deploy_helm ;;
esac

post_deploy_verify
