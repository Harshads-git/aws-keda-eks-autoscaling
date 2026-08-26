#!/usr/bin/env bash
# =============================================================================
# install-keda.sh
# Installs KEDA (Kubernetes Event-Driven Autoscaling) on the EKS cluster
# using Helm, with the KEDA operator ServiceAccount annotated for IRSA.
#
# KEDA components installed:
#   keda-operator            → watches ScaledObjects, manages HPA lifecycle
#   keda-metrics-apiserver   → exposes external metrics to the K8s HPA
#   keda-admission-webhooks  → validates KEDA CRDs on creation
#
# IRSA setup:
#   The KEDA operator SA is annotated with keda-operator-role ARN.
#   This allows KEDA to call SQS GetQueueAttributes without static credentials.
#
# Usage:
#   bash scripts/install-keda.sh
#   bash scripts/install-keda.sh --dry-run
#   bash scripts/install-keda.sh --upgrade    (upgrades existing installation)
#   bash scripts/install-keda.sh --uninstall  (removes KEDA entirely)
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#     (run: terraform output -raw kubeconfig_command | bash)
#   - Helm 3 installed
#   - KEDA operator IAM role ARN in .env as KEDA_OPERATOR_ROLE_ARN
#     (get: terraform output -raw keda_operator_role_arn)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

KEDA_VERSION="${KEDA_VERSION:-2.13.0}"
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"

# ─── Parse Arguments ──────────────────────────────────────────────────────────
DRY_RUN=false
UPGRADE=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)   DRY_RUN=true;   shift ;;
    --upgrade)   UPGRADE=true;   shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--upgrade] [--uninstall]"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Load Environment ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a; source "${PROJECT_ROOT}/.env"; set +a
fi

# Try to get KEDA_OPERATOR_ROLE_ARN from Terraform output if not in env
if [ -z "${KEDA_OPERATOR_ROLE_ARN:-}" ] && command -v terraform &>/dev/null; then
  echo -e "${YELLOW}⚠${NC}  KEDA_OPERATOR_ROLE_ARN not in .env — trying terraform output..."
  KEDA_OPERATOR_ROLE_ARN=$(terraform -chdir="${PROJECT_ROOT}/terraform" output -raw keda_operator_role_arn 2>/dev/null || echo "")
fi

if [ -z "${KEDA_OPERATOR_ROLE_ARN:-}" ]; then
  echo -e "${RED}✘${NC}  KEDA_OPERATOR_ROLE_ARN is required."
  echo -e "     Get it: terraform -chdir=terraform output -raw keda_operator_role_arn"
  echo -e "     Then:   export KEDA_OPERATOR_ROLE_ARN=<arn> or add to .env"
  exit 1
fi

# ─── Uninstall Path ───────────────────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
  echo -e "${YELLOW}${BOLD}Uninstalling KEDA from namespace ${KEDA_NAMESPACE}...${NC}"
  helm uninstall keda --namespace "$KEDA_NAMESPACE" 2>/dev/null || \
    echo -e "${YELLOW}⚠${NC}  KEDA not found in ${KEDA_NAMESPACE} — may already be uninstalled"
  kubectl delete namespace "$KEDA_NAMESPACE" --ignore-not-found=true
  echo -e "${GREEN}✔${NC}  KEDA uninstalled"
  exit 0
fi

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   Install KEDA ${KEDA_VERSION} on EKS                         ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Cluster:    $(kubectl config current-context 2>/dev/null || echo 'not configured')"
echo -e "  Namespace:  ${KEDA_NAMESPACE}"
echo -e "  KEDA ver:   ${KEDA_VERSION}"
echo -e "  IRSA Role:  ${KEDA_OPERATOR_ROLE_ARN}"
echo -e "  Dry run:    ${DRY_RUN} | Upgrade: ${UPGRADE}"
echo ""

# ─── Step 1: Add/Update Helm Repo ────────────────────────────────────────────
echo -e "${BOLD}[1/4] Adding KEDA Helm repository...${NC}"
if [ "$DRY_RUN" = false ]; then
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || \
    echo -e "  ${YELLOW}⚠${NC}  kedacore repo already added"
  helm repo update kedacore
  echo -e "${GREEN}✔${NC}  Helm repo ready"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would add kedacore Helm repo"
fi

# ─── Step 2: Create KEDA Namespace ───────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] Creating KEDA namespace...${NC}"
if [ "$DRY_RUN" = false ]; then
  kubectl create namespace "$KEDA_NAMESPACE" --dry-run=client -o yaml | \
    kubectl apply -f -
  echo -e "${GREEN}✔${NC}  Namespace ${KEDA_NAMESPACE} ready"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create namespace: ${KEDA_NAMESPACE}"
fi

# ─── Step 3: Install/Upgrade KEDA ────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/4] $([ "$UPGRADE" = true ] && echo "Upgrading" || echo "Installing") KEDA...${NC}"

HELM_CMD="helm $([ "$UPGRADE" = true ] && echo "upgrade --install" || echo "install") keda kedacore/keda"

HELM_ARGS=(
  "--namespace" "${KEDA_NAMESPACE}"
  "--version" "${KEDA_VERSION}"
  "--set" "watchNamespace=''"               # Watch ALL namespaces (including keda-demo)
  "--set" "operator.replicaCount=1"         # 1 operator replica (dev; use 2 in prod)
  "--set" "metricsServer.replicaCount=1"    # 1 metrics server replica
  # ── IRSA Annotation ──────────────────────────────────────────────────────
  # This is the critical annotation that enables KEDA to call SQS.
  # KEDA operator SA gets this annotation → EKS webhook injects OIDC token
  # → KEDA calls STS AssumeRoleWithWebIdentity → gets temp creds
  # → KEDA calls sqs:GetQueueAttributes to read ApproximateNumberOfMessages
  "--set" "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KEDA_OPERATOR_ROLE_ARN}"
  "--set" "podSecurityContext.fsGroup=1000"
  # Resource limits for t3.micro (tight but functional)
  "--set" "resources.operator.requests.cpu=50m"
  "--set" "resources.operator.requests.memory=64Mi"
  "--set" "resources.operator.limits.cpu=200m"
  "--set" "resources.operator.limits.memory=256Mi"
  "--set" "resources.metricServer.requests.cpu=50m"
  "--set" "resources.metricServer.requests.memory=64Mi"
  "--set" "resources.metricServer.limits.cpu=200m"
  "--set" "resources.metricServer.limits.memory=256Mi"
  "--wait"                                  # Wait for all pods to be Ready
  "--timeout" "5m"
)

if [ "$DRY_RUN" = false ]; then
  ${HELM_CMD} "${HELM_ARGS[@]}"
  echo -e "${GREEN}✔${NC}  KEDA installed successfully"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would run:"
  echo -e "     ${HELM_CMD} \\"
  for arg in "${HELM_ARGS[@]}"; do
    echo -e "       ${arg} \\"
  done
fi

# ─── Step 4: Verify Installation ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/4] Verifying KEDA installation...${NC}"
if [ "$DRY_RUN" = false ]; then
  echo -e "  ${BLUE}Pods in keda namespace:${NC}"
  kubectl get pods -n "$KEDA_NAMESPACE" | sed 's/^/  /'

  echo ""
  echo -e "  ${BLUE}KEDA CRDs installed:${NC}"
  kubectl get crd | grep keda | sed 's/^/  /'

  # Check IRSA is working: KEDA operator pod should have the IRSA env var injected
  echo ""
  echo -e "  ${BLUE}Checking IRSA annotation on KEDA operator SA:${NC}"
  kubectl get serviceaccount keda-operator -n "$KEDA_NAMESPACE" \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' \
    2>/dev/null | sed 's/^/  /' || echo -e "  ${YELLOW}⚠${NC}  SA not found yet"
  echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   KEDA Installation Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Deploy your app manifests:"
echo -e "  ${BLUE}SQS_QUEUE_URL=\$(terraform -chdir=terraform output -raw sqs_queue_url) \\"
echo -e "  IMAGE_TAG=sha-<your-sha> bash scripts/deploy-all-manifests.sh${NC}"
echo ""
echo -e "  Watch KEDA scale your pods:"
echo -e "  ${BLUE}kubectl get pods -n keda-demo -w${NC}"
echo ""
echo -e "  Trigger autoscaling:"
echo -e "  ${BLUE}bash scripts/generate-messages.sh --count 25${NC}"
echo ""
