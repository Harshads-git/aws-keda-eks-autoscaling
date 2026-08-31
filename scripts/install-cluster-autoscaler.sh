#!/usr/bin/env bash
# =============================================================================
# install-cluster-autoscaler.sh
# Installs the Kubernetes Cluster Autoscaler via Helm with IRSA annotation.
# CA must be configured with your exact cluster name and AWS region to discover
# its managed Auto Scaling groups.
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#   - terraform apply completed (cluster-autoscaler IAM role exists)
#   - EKS node group has CA discovery tags (set in terraform/modules/eks/node-group.tf)
#
# Usage:
#   bash scripts/install-cluster-autoscaler.sh
#   bash scripts/install-cluster-autoscaler.sh --dry-run
#   bash scripts/install-cluster-autoscaler.sh --upgrade
#   bash scripts/install-cluster-autoscaler.sh --uninstall
#
# After install, trigger CA by overwhelming the existing nodes:
#   bash scripts/generate-messages.sh --count 100   (forces more pods than 1 node can hold)
#   watch kubectl get nodes  (observe a 2nd node appear after ~3-5 min)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Parse Arguments ──────────────────────────────────────────────────────────
DRY_RUN=false
UPGRADE=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)   DRY_RUN=true;   shift ;;
    --upgrade)   UPGRADE=true;   shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    --help|-h)   echo "Usage: $0 [--dry-run] [--upgrade] [--uninstall]"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Load Environment ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"

if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a; source "${PROJECT_ROOT}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"

# ─── Resolve Required Values ─────────────────────────────────────────────────
echo -e "${BOLD}Resolving configuration...${NC}"

# Get cluster name from Terraform or environment
if [ -z "${EKS_CLUSTER_NAME:-}" ] && command -v terraform &>/dev/null; then
  EKS_CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_name 2>/dev/null || echo "")
fi
if [ -z "${EKS_CLUSTER_NAME:-}" ]; then
  echo -e "${RED}✘${NC}  EKS_CLUSTER_NAME not set. Get it: terraform output -raw cluster_name"
  exit 1
fi

# Get CA role ARN from Terraform
if [ -z "${CA_ROLE_ARN:-}" ] && command -v terraform &>/dev/null; then
  CA_ROLE_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_autoscaler_role_arn 2>/dev/null || echo "")
fi
if [ -z "${CA_ROLE_ARN:-}" ]; then
  echo -e "${RED}✘${NC}  CA_ROLE_ARN not set. Get it: terraform output -raw cluster_autoscaler_role_arn"
  exit 1
fi

# ─── Uninstall Path ───────────────────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
  echo -e "${YELLOW}Uninstalling Cluster Autoscaler...${NC}"
  helm uninstall cluster-autoscaler --namespace kube-system 2>/dev/null || \
    echo -e "${YELLOW}⚠${NC}  CA not found — may already be uninstalled"
  echo -e "${GREEN}✔${NC}  Cluster Autoscaler uninstalled"
  exit 0
fi

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   Install Cluster Autoscaler                           ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Cluster:     ${EKS_CLUSTER_NAME}"
echo -e "  Region:      ${AWS_REGION}"
echo -e "  IRSA Role:   ${CA_ROLE_ARN}"
echo -e "  Dry run:     ${DRY_RUN} | Upgrade: ${UPGRADE}"
echo ""

# ─── Step 1: Add Helm Repo ────────────────────────────────────────────────────
echo -e "${BOLD}[1/4] Adding autoscaler Helm repository...${NC}"
if [ "$DRY_RUN" = false ]; then
  helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || \
    echo -e "  ${YELLOW}⚠${NC}  autoscaler repo already added"
  helm repo update autoscaler
  echo -e "${GREEN}✔${NC}  Helm repo ready"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would add autoscaler Helm repo"
fi

# ─── Step 2: Verify Node Group Tags ──────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] Verifying node group has CA discovery tags...${NC}"
echo -e "      CA discovers node groups via ASG tags:"
echo -e "        k8s.io/cluster-autoscaler/${EKS_CLUSTER_NAME} = owned"
echo -e "        k8s.io/cluster-autoscaler/enabled = true"

if [ "$DRY_RUN" = false ]; then
  # Check if any ASG has the CA tags for this cluster
  ASG_COUNT=$(aws autoscaling describe-auto-scaling-groups \
    --filters "Name=tag:k8s.io/cluster-autoscaler/${EKS_CLUSTER_NAME},Values=owned" \
    --query 'length(AutoScalingGroups)' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "0")

  if [ "$ASG_COUNT" -ge 1 ]; then
    echo -e "${GREEN}✔${NC}  Found ${ASG_COUNT} Auto Scaling group(s) tagged for CA discovery"
  else
    echo -e "${YELLOW}⚠${NC}  No tagged ASGs found. CA will start but may not find node groups."
    echo -e "     Check: terraform apply ran and node group exists"
  fi
fi

# ─── Step 3: Install/Upgrade Cluster Autoscaler ──────────────────────────────
echo ""
echo -e "${BOLD}[3/4] $([ "$UPGRADE" = true ] && echo "Upgrading" || echo "Installing") Cluster Autoscaler...${NC}"

HELM_CMD="helm $([ "$UPGRADE" = true ] && echo "upgrade --install" || echo "install") cluster-autoscaler autoscaler/cluster-autoscaler"

HELM_ARGS=(
  "--namespace" "kube-system"
  "--set" "autoDiscovery.clusterName=${EKS_CLUSTER_NAME}"
  "--set" "awsRegion=${AWS_REGION}"
  # ── IRSA Annotation ───────────────────────────────────────────────────────
  # Tells EKS pod identity webhook to inject IRSA credentials
  # CA pod gets AWS_ROLE_ARN + JWT token file → calls STS → temp credentials
  "--set" "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${CA_ROLE_ARN}"
  # ── CA Behaviour Tuning ───────────────────────────────────────────────────
  "--set" "extraArgs.balance-similar-node-groups=true"
  # Scale down: remove a node only if it's been underutilized for 10 minutes
  "--set" "extraArgs.scale-down-unneeded-time=10m"
  # Scale down: wait 10 minutes after a scale-up before scaling down
  "--set" "extraArgs.scale-down-delay-after-add=10m"
  # Scan interval: how often CA checks for unschedulable pods
  "--set" "extraArgs.scan-interval=30s"
  # Skip nodes with local storage (PVCs) during scale-down
  "--set" "extraArgs.skip-nodes-with-local-storage=false"
  # ── Resource Limits ───────────────────────────────────────────────────────
  "--set" "resources.requests.cpu=50m"
  "--set" "resources.requests.memory=64Mi"
  "--set" "resources.limits.cpu=200m"
  "--set" "resources.limits.memory=128Mi"
  "--wait"
  "--timeout" "5m"
)

if [ "$DRY_RUN" = false ]; then
  ${HELM_CMD} "${HELM_ARGS[@]}"
  echo -e "${GREEN}✔${NC}  Cluster Autoscaler installed"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would run:"
  echo "   ${HELM_CMD} \\"
  for arg in "${HELM_ARGS[@]}"; do
    echo "     ${arg} \\"
  done
fi

# ─── Step 4: Verify Installation ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/4] Verifying installation...${NC}"
if [ "$DRY_RUN" = false ]; then
  echo -e "  ${BLUE}CA pod status:${NC}"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler \
    2>/dev/null | sed 's/^/  /' || echo "  (no pods found yet — may still be starting)"

  echo ""
  echo -e "  ${BLUE}CA deployment:${NC}"
  kubectl get deploy -n kube-system cluster-autoscaler 2>/dev/null | sed 's/^/  /' || true

  echo ""
  echo -e "  ${BLUE}IRSA annotation on CA ServiceAccount:${NC}"
  kubectl get serviceaccount cluster-autoscaler -n kube-system \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' \
    2>/dev/null | sed 's/^/  /' || echo "  (SA not found — check install above)"
  echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Cluster Autoscaler Installed!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Watch CA logs:${NC}"
echo -e "  ${BLUE}kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f${NC}"
echo ""
echo -e "  ${BOLD}Trigger node scale-up (overflow 1 node's capacity):${NC}"
echo -e "  ${BLUE}bash scripts/generate-messages.sh --count 100${NC}"
echo -e "  ${BLUE}kubectl get nodes -w${NC}  (watch for new node)"
echo ""
echo -e "  ${BOLD}Node scaling timing:${NC}"
echo -e "  KEDA creates pods → pods Pending (no capacity) → CA triggers → EC2 boot (~3-5 min)"
echo ""
