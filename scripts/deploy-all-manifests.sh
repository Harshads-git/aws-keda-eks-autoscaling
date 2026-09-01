#!/usr/bin/env bash
# =============================================================================
# deploy-all-manifests.sh
# Deploys all Kubernetes manifests to EKS in the correct order.
# Uses envsubst to inject runtime values (ECR URI, SQS URL, etc.) before apply.
#
# Deployment order matters:
#   1. Namespace + ResourceQuota   (must exist before anything else)
#   2. ServiceAccount              (must exist before Deployment references it)
#   3. ConfigMap                   (must exist before Deployment mounts it)
#   4. Deployment                  (references SA + ConfigMap)
#   5. TriggerAuthentication       (KEDA CRD — must exist before ScaledObject)
#   6. ScaledObject                (KEDA CRD — references Deployment + TriggerAuth)
#
# envsubst replaces ${VAR} placeholders in YAML files with actual values.
# This pattern avoids hardcoding account IDs, queue URLs, and image tags.
#
# Usage:
#   bash scripts/deploy-all-manifests.sh
#   bash scripts/deploy-all-manifests.sh --dry-run   (kubectl --dry-run=client)
#   bash scripts/deploy-all-manifests.sh --watch     (watch pods after deploy)
#   IMAGE_TAG=sha-abc1234 bash scripts/deploy-all-manifests.sh
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#     (aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION)
#   - KEDA installed (scripts/install-keda.sh — Day 16)
#   - .env with ECR_REPO_URI, SQS_QUEUE_URL, AWS_ACCOUNT_ID, IMAGE_TAG
# =============================================================================

set -euo pipefail

# ─── Colour Codes ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Parse Arguments ──────────────────────────────────────────────────────────
DRY_RUN=false
WATCH=false
KUBECTL_FLAGS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)  DRY_RUN=true; KUBECTL_FLAGS="--dry-run=client"; shift ;;
    --watch|-w) WATCH=true;   shift ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--watch]"
      echo "  --dry-run  Validate manifests without applying to cluster"
      echo "  --watch    Watch pod scaling after deployment"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Load Environment ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${PROJECT_ROOT}/manifests"

if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a; source "${PROJECT_ROOT}/.env"; set +a
  echo -e "${GREEN}✔${NC}  Loaded .env"
else
  echo -e "${YELLOW}⚠${NC}  No .env found — using environment variables as-is"
fi

# ─── Validate Required Variables ─────────────────────────────────────────────
MISSING=()
[ -z "${ECR_REPO_URI:-}"   ] || [[ "${ECR_REPO_URI}"   == *"REPLACE"* ]] && MISSING+=("ECR_REPO_URI")
[ -z "${SQS_QUEUE_URL:-}"  ] || [[ "${SQS_QUEUE_URL}"  == *"REPLACE"* ]] && MISSING+=("SQS_QUEUE_URL")
[ -z "${AWS_ACCOUNT_ID:-}" ] || [[ "${AWS_ACCOUNT_ID}" == *"REPLACE"* ]] && MISSING+=("AWS_ACCOUNT_ID")
IMAGE_TAG="${IMAGE_TAG:-latest}"

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}✘${NC}  Missing required variables in .env:"
  for v in "${MISSING[@]}"; do
    echo -e "     - ${v}"
  done
  echo ""
  echo -e "     Run setup scripts first:"
  echo -e "     1. bash scripts/setup-sqs.sh   → sets SQS_QUEUE_URL"
  echo -e "     2. bash scripts/setup-ecr.sh   → sets ECR_REPO_URI"
  echo -e "     3. terraform apply             → sets AWS_ACCOUNT_ID"
  exit 1
fi

# Compute ConfigMap hash for deployment annotation (forces pod restart on CM change)
CONFIGMAP_HASH=$(cat "${MANIFESTS_DIR}/configmap.yaml" | md5sum | cut -d' ' -f1 2>/dev/null || echo "unknown")

# Git SHA for deployment annotation
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Export all variables for envsubst
export ECR_REPO_URI SQS_QUEUE_URL AWS_ACCOUNT_ID IMAGE_TAG GIT_SHA CONFIGMAP_HASH
export AWS_REGION="${AWS_REGION:-us-east-1}"
export APP_NAMESPACE="${APP_NAMESPACE:-keda-demo}"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   Deploy All Manifests — KEDA Demo on EKS             ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Cluster:    $(kubectl config current-context 2>/dev/null || echo 'not configured')"
echo -e "  Namespace:  ${APP_NAMESPACE}"
echo -e "  Image:      ${ECR_REPO_URI}:${IMAGE_TAG}"
echo -e "  Queue:      ${SQS_QUEUE_URL}"
echo -e "  Dry run:    ${DRY_RUN}"
echo ""
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}${BOLD}DRY RUN — manifests will be validated but not applied${NC}"

# ─── Helper: Apply a Manifest ─────────────────────────────────────────────────
apply_manifest() {
  local file=$1
  local description=$2
  local basename
  basename=$(basename "$file")

  echo -e "  ${CYAN}→${NC}  ${description}"

  if [ "$DRY_RUN" = false ]; then
    # envsubst replaces ${VAR} placeholders in YAML with actual values
    # then pipes to kubectl apply
    envsubst < "$file" | kubectl apply -f - $KUBECTL_FLAGS 2>&1 | \
      sed 's/^/     /'  # indent kubectl output
  else
    echo -e "     ${YELLOW}[DRY RUN] Would apply: ${basename}${NC}"
    # Validate YAML is well-formed with envsubst applied
    envsubst < "$file" | kubectl apply -f - --dry-run=client 2>&1 | \
      sed 's/^/     /'
  fi
}

# ─── Deployment Sequence ──────────────────────────────────────────────────────
echo -e "${BOLD}Deploying manifests in dependency order...${NC}"
echo ""

# Step 1: Namespace and ResourceQuota (foundation — everything else goes in here)
apply_manifest \
  "${MANIFESTS_DIR}/namespace.yaml" \
  "[1/6] Namespace: keda-demo + ResourceQuota"
echo ""

# Step 2: ServiceAccount with IRSA annotation
# (must exist before Deployment uses serviceAccountName: keda-demo)
apply_manifest \
  "${MANIFESTS_DIR}/serviceaccount.yaml" \
  "[2/6] ServiceAccount: keda-demo (IRSA annotated)"
echo ""

# Step 3: ConfigMap with app configuration
# (must exist before Deployment references it via envFrom: configMapRef)
apply_manifest \
  "${MANIFESTS_DIR}/configmap.yaml" \
  "[3/6] ConfigMap: keda-demo-config (SQS URL, region, log level)"
echo ""

# Step 4: Deployment
# (references ServiceAccount + ConfigMap, pulls image from ECR)
apply_manifest \
  "${MANIFESTS_DIR}/deployment.yaml" \
  "[4/6] Deployment: keda-demo (image: ${ECR_REPO_URI}:${IMAGE_TAG})"
echo ""

# Step 5: KEDA TriggerAuthentication
# (KEDA CRD — must exist before ScaledObject references it)
apply_manifest \
  "${MANIFESTS_DIR}/keda-trigger-auth.yaml" \
  "[5/6] TriggerAuthentication: keda-trigger-auth-aws (IRSA pod identity)"
echo ""

# Step 6: KEDA ScaledObject
# (KEDA CRD — the autoscaler brain, references Deployment + TriggerAuthentication)
apply_manifest \
  "${MANIFESTS_DIR}/keda-scaled-object.yaml" \
  "[6/7] ScaledObject: keda-demo-scaledobject (SQS trigger, 0→5 replicas)"
echo ""

# Step 7: PodDisruptionBudget
# (applied last — protects running pods from CA drain during node scale-down)
apply_manifest \
  "${MANIFESTS_DIR}/pdb.yaml" \
  "[7/7] PodDisruptionBudget: keda-demo-pdb (maxUnavailable=1 during node drain)"
echo ""

# ─── Post-Deploy Verification ────────────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
  echo -e "${BOLD}Verifying deployment...${NC}"
  echo ""

  echo -e "  ${CYAN}Pods in keda-demo namespace:${NC}"
  kubectl get pods -n keda-demo 2>/dev/null | sed 's/^/  /' || \
    echo -e "  ${YELLOW}⚠${NC}  No pods yet (expected — KEDA scales to 0 when queue is empty)"

  echo ""
  echo -e "  ${CYAN}ScaledObject status:${NC}"
  kubectl get scaledobject -n keda-demo 2>/dev/null | sed 's/^/  /' || \
    echo -e "  ${YELLOW}⚠${NC}  ScaledObject not found — is KEDA installed? Run scripts/install-keda.sh"

  echo ""
  echo -e "  ${CYAN}HPA (created by KEDA):${NC}"
  kubectl get hpa -n keda-demo 2>/dev/null | sed 's/^/  /' || \
    echo -e "  ${YELLOW}⚠${NC}  HPA not yet created — KEDA creates it after ScaledObject reconciliation (~30s)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Deployment Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Test autoscaling:"
echo -e "  ${CYAN}# Terminal 1: Watch pods${NC}"
echo -e "  kubectl get pods -n keda-demo -w"
echo ""
echo -e "  ${CYAN}# Terminal 2: Send messages to trigger scale-up${NC}"
echo -e "  bash scripts/generate-messages.sh --count 25"
echo ""
echo -e "  ${CYAN}# Check KEDA ScaledObject status${NC}"
echo -e "  kubectl describe scaledobject keda-demo-scaledobject -n keda-demo"
echo ""

# ─── Watch Mode ───────────────────────────────────────────────────────────────
if [ "$WATCH" = true ] && [ "$DRY_RUN" = false ]; then
  echo -e "${BOLD}Watching pods (Ctrl+C to exit)...${NC}"
  kubectl get pods -n keda-demo -w
fi
