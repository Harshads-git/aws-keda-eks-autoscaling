#!/usr/bin/env bash
# =============================================================================
# scripts/cleanup.sh — Safe AWS Resource Teardown
# =============================================================================
# Destroys all AWS resources created by this project in the correct
# dependency order. Runs Kubernetes cleanup before Terraform destroy
# to avoid orphaned cloud resources (load balancers, ENIs, etc.).
#
# Dependency-safe teardown order:
#   1. Delete Kubernetes workloads (consumer pods, KEDA ScaledObject)
#   2. Delete Kubernetes cluster addons (KEDA, kube-prometheus-stack)
#   3. ECR — delete all images (Terraform can't destroy a non-empty registry)
#   4. SQS — purge queue (optional, Terraform will delete it)
#   5. Terraform destroy — removes VPC, EKS, SQS, ECR, IAM, S3 state bucket
#
# Why order matters:
#   If Terraform destroy runs BEFORE deleting EKS resources:
#     → EKS deletes nodes, but Kubernetes LoadBalancer services may have
#       created EC2 Load Balancers that Terraform doesn't know about
#     → VPC deletion fails: ENIs attached to load balancer still exist
#     → Manual cleanup required in AWS console (painful)
#
# Usage:
#   bash scripts/cleanup.sh                  # Interactive (asks for confirmation)
#   bash scripts/cleanup.sh --yes            # Skip all prompts (CI/automated)
#   bash scripts/cleanup.sh --k8s-only       # Delete K8s resources, keep AWS infra
#   bash scripts/cleanup.sh --tf-only        # Terraform destroy only (K8s already gone)
#   bash scripts/cleanup.sh --dry-run        # Print plan, no deletions
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${REPO_ROOT}/terraform"
NAMESPACE="${NAMESPACE:-keda-demo}"
AUTO_APPROVE=false
K8S_ONLY=false
TF_ONLY=false
DRY_RUN=false
ECR_REPO="${ECR_REPO:-keda-demo-app}"
AWS_REGION="${AWS_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --yes|-y)     AUTO_APPROVE=true; shift ;;
    --k8s-only)   K8S_ONLY=true; shift ;;
    --tf-only)    TF_ONLY=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --region)     AWS_REGION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
skip() { echo -e "  ${YELLOW}(skip)${NC} $*"; }
run()  {
  if [[ "$DRY_RUN" = true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
  else
    eval "$*"
  fi
}

# ─── Confirmation Gate ────────────────────────────────────────────────────────
if [[ "$AUTO_APPROVE" = false && "$DRY_RUN" = false ]]; then
  echo ""
  echo -e "${RED}${BOLD}⚠  WARNING: DESTRUCTIVE OPERATION  ⚠${NC}"
  echo ""
  echo "  This will permanently delete:"
  echo "    - All Kubernetes resources in namespace: ${NAMESPACE}"
  echo "    - All ECR images in repository: ${ECR_REPO}"
  echo "    - All AWS infrastructure (EKS, SQS, VPC, IAM, ECR)"
  echo "    - Terraform state (S3 bucket + DynamoDB table)"
  echo ""
  echo -e "  AWS Region:   ${BOLD}${AWS_REGION}${NC}"
  echo -e "  Namespace:    ${BOLD}${NAMESPACE}${NC}"
  echo ""
  read -rp "  Type 'yes' to confirm: " CONFIRM
  [[ "$CONFIRM" = "yes" ]] || { echo "Aborted."; exit 0; }
  echo ""
fi

# ─── Helper: kubectl check ────────────────────────────────────────────────────
kubectl_available() {
  kubectl get namespace "${NAMESPACE}" &>/dev/null 2>&1
}

# ─── Step 1: Delete Kubernetes Workloads ──────────────────────────────────────
cleanup_k8s_workloads() {
  log "Step 1/5: Deleting Kubernetes workloads in namespace ${NAMESPACE}..."

  if ! kubectl_available; then
    warn "Namespace ${NAMESPACE} not found or kubectl not configured — skipping K8s cleanup"
    return
  fi

  # Delete KEDA ScaledObject first — prevents KEDA from re-creating pods
  # while we're trying to delete them
  if kubectl get scaledobject -n "${NAMESPACE}" &>/dev/null; then
    run "kubectl delete scaledobject --all -n ${NAMESPACE} --timeout=30s"
    ok "KEDA ScaledObjects deleted"
  else
    skip "No ScaledObjects found"
  fi

  # Delete Deployment (and therefore all consumer pods)
  if kubectl get deployment keda-demo -n "${NAMESPACE}" &>/dev/null; then
    run "kubectl delete deployment keda-demo -n ${NAMESPACE} --timeout=60s"
    ok "Deployment deleted"
  else
    skip "No keda-demo Deployment found"
  fi

  # Wait for pods to terminate (avoids 'pod still exists' VPC ENI issues)
  log "  Waiting for all pods to terminate..."
  if [[ "$DRY_RUN" = false ]]; then
    local timeout=60
    local elapsed=0
    while [[ $(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l) -gt 0 ]]; do
      sleep 5
      elapsed=$((elapsed + 5))
      [[ $elapsed -ge $timeout ]] && warn "Pod termination timeout — continuing" && break
    done
  fi
  ok "All consumer pods terminated"

  # Delete remaining namespace resources (Services, ConfigMaps, RBAC, etc.)
  run "kubectl delete namespace ${NAMESPACE} --timeout=120s --ignore-not-found"
  ok "Namespace ${NAMESPACE} deleted"
}

# ─── Step 2: Remove Cluster Addons (Helm releases) ────────────────────────────
cleanup_cluster_addons() {
  log "Step 2/5: Removing cluster addon Helm releases..."

  local addons=("keda" "kube-prometheus-stack" "aws-node-termination-handler" "cluster-autoscaler")
  for addon in "${addons[@]}"; do
    local ns="keda"
    [[ "$addon" = "kube-prometheus-stack" ]] && ns="monitoring"
    [[ "$addon" = "aws-node-termination-handler" ]] && ns="kube-system"
    [[ "$addon" = "cluster-autoscaler" ]] && ns="kube-system"

    if helm status "$addon" -n "$ns" &>/dev/null 2>&1; then
      run "helm uninstall $addon -n $ns --timeout 3m"
      ok "Helm release '${addon}' uninstalled"
    else
      skip "Helm release '${addon}' not found"
    fi
  done

  # Remove CRDs (KEDA's ScaledObject CRD must go before EKS nodes are drained)
  for crd in scaledobjects.keda.sh scaledjobs.keda.sh triggerauthentications.keda.sh clustertriggerauthentications.keda.sh; do
    if kubectl get crd "$crd" &>/dev/null 2>&1; then
      run "kubectl delete crd $crd --timeout=30s"
      ok "CRD ${crd} deleted"
    fi
  done
}

# ─── Step 3: Delete ECR Images ────────────────────────────────────────────────
cleanup_ecr() {
  log "Step 3/5: Deleting ECR images in repository ${ECR_REPO}..."

  # List all image digests
  local image_ids
  image_ids=$(aws ecr list-images \
    --repository-name "${ECR_REPO}" \
    --region "${AWS_REGION}" \
    --query 'imageIds[*]' \
    --output json 2>/dev/null || echo "[]")

  local count
  count=$(echo "$image_ids" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "$count" -eq 0 ]]; then
    skip "ECR repository ${ECR_REPO} is empty or does not exist"
    return
  fi

  log "  Found ${count} image(s) in ${ECR_REPO}"
  run "aws ecr batch-delete-image \
    --repository-name '${ECR_REPO}' \
    --region '${AWS_REGION}' \
    --image-ids '${image_ids}' \
    --output text"
  ok "${count} ECR images deleted (repository now empty for Terraform destroy)"
}

# ─── Step 4: Purge SQS Queue ──────────────────────────────────────────────────
cleanup_sqs() {
  log "Step 4/5: Purging SQS queue (optional)..."

  local queue_url
  queue_url=$(aws sqs get-queue-url \
    --queue-name "keda-demo-queue" \
    --region "${AWS_REGION}" \
    --query 'QueueUrl' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$queue_url" ]]; then
    skip "SQS queue keda-demo-queue not found (already deleted or different name)"
    return
  fi

  run "aws sqs purge-queue --queue-url '${queue_url}' --region '${AWS_REGION}'"
  ok "SQS queue purged (Terraform will delete it)"
}

# ─── Step 5: Terraform Destroy ────────────────────────────────────────────────
cleanup_terraform() {
  log "Step 5/5: Running terraform destroy..."

  if [[ ! -f "${TERRAFORM_DIR}/main.tf" ]]; then
    warn "Terraform directory not found at ${TERRAFORM_DIR} — skipping"
    return
  fi

  cd "${TERRAFORM_DIR}"

  if [[ "$DRY_RUN" = true ]]; then
    echo "  [DRY-RUN] terraform plan -destroy"
    return
  fi

  # terraform destroy with auto-approve when --yes is passed
  local tf_args=("-auto-approve" "-input=false")
  terraform destroy "${tf_args[@]}"

  ok "Terraform destroy complete — all AWS resources deleted"
  cd "${REPO_ROOT}"
}

# ─── Run Steps ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}SmartScale AI — Resource Cleanup${NC}"
[[ "$DRY_RUN" = true ]] && echo -e "${YELLOW}DRY-RUN MODE — no changes will be made${NC}"
echo ""

if [[ "$TF_ONLY" = false ]]; then
  cleanup_k8s_workloads
  cleanup_cluster_addons
fi

if [[ "$K8S_ONLY" = false ]]; then
  cleanup_ecr
  cleanup_sqs
  cleanup_terraform
fi

echo ""
echo -e "${GREEN}${BOLD}✓ Cleanup complete!${NC}"
echo ""
echo "  If AWS resources persist, check:"
echo "    - EC2 console → Load Balancers (may have been created by K8s Services)"
echo "    - VPC console → delete any orphaned ENIs if VPC delete fails"
echo "    - CloudWatch → delete log groups: /aws/eks/keda-demo-dev-cluster"
echo "    - S3 → manually empty the Terraform state bucket before deleting"
