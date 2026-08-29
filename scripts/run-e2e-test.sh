#!/usr/bin/env bash
# =============================================================================
# run-e2e-test.sh
# Full end-to-end test of the KEDA autoscaling stack.
# Validates the complete flow:
#   1. SQS queue is empty → KEDA has 0 pods (scale-to-zero)
#   2. Send N messages → KEDA scales up to ceil(N/5) pods
#   3. Consumer pods process all messages → queue drains
#   4. Queue empty → KEDA scales back to 0 (scale-to-zero)
#
# This test proves the ENTIRE stack works end-to-end:
#   SQS → KEDA metric polling → HPA scale-up → Pod scheduling
#   → IRSA credential injection → app.py consuming → SQS DeleteMessage
#   → Queue drains → KEDA scale-down → 0 pods (scale-to-zero)
#
# Usage:
#   bash scripts/run-e2e-test.sh
#   bash scripts/run-e2e-test.sh --messages 50  (default: 25)
#   bash scripts/run-e2e-test.sh --no-wait       (skip scale-down observation)
#   bash scripts/run-e2e-test.sh --dry-run       (validate config, no SQS calls)
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#   - KEDA installed (bash scripts/install-keda.sh)
#   - App manifests deployed (bash scripts/deploy-all-manifests.sh)
#   - SQS_QUEUE_URL in environment or .env
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Default Config ───────────────────────────────────────────────────────────
MESSAGE_COUNT=25            # Messages to send (25 / queueLength=5 = 5 replicas)
K8S_NAMESPACE="keda-demo"  # Namespace where consumer pods run
SCALE_UP_TIMEOUT=180       # Seconds to wait for pods to appear
PROCESS_TIMEOUT=300        # Seconds to wait for queue to drain
SCALE_DOWN_TIMEOUT=400     # Seconds to wait for scale-to-zero (cooldown=300s + margin)
DRY_RUN=false
NO_WAIT=false

PASS_COUNT=0
FAIL_COUNT=0

# ─── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --messages) MESSAGE_COUNT="$2"; shift 2 ;;
    --no-wait)  NO_WAIT=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--messages N] [--no-wait] [--dry-run]"
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

# Auto-resolve SQS_QUEUE_URL from Terraform if not set
if [ -z "${SQS_QUEUE_URL:-}" ] && command -v terraform &>/dev/null; then
  SQS_QUEUE_URL=$(terraform -chdir="${PROJECT_ROOT}/terraform" output -raw sqs_queue_url 2>/dev/null || echo "")
fi

if [ -z "${SQS_QUEUE_URL:-}" ]; then
  echo -e "${RED}✘${NC}  SQS_QUEUE_URL is required."
  echo -e "     Get it: cd terraform && terraform output -raw sqs_queue_url"
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
pass() { echo -e "${GREEN}✔${NC}  PASS: $1"; ((PASS_COUNT++)); }
fail() { echo -e "${RED}✘${NC}  FAIL: $1"; ((FAIL_COUNT++)); }

get_queue_depth() {
  aws sqs get-queue-attributes \
    --queue-url "$SQS_QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "0"
}

get_running_pods() {
  kubectl get pods -n "$K8S_NAMESPACE" \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_total_pods() {
  kubectl get pods -n "$K8S_NAMESPACE" \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_scaledobject_ready() {
  kubectl get scaledobject -n "$K8S_NAMESPACE" \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || echo "Unknown"
}

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   KEDA End-to-End Autoscaling Test                    ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Queue URL:   ${SQS_QUEUE_URL:0:60}..."
echo -e "  Namespace:   ${K8S_NAMESPACE}"
echo -e "  Messages:    ${MESSAGE_COUNT}"
echo -e "  Dry run:     ${DRY_RUN}"
echo ""

START_TIME=$(date +%s)

# ─── Phase 1: Verify Prerequisites ───────────────────────────────────────────
echo -e "${BOLD}Phase 1: Prerequisite Checks${NC}"
echo "────────────────────────────────────────"

# Check kubectl
if ! kubectl cluster-info &>/dev/null; then
  fail "kubectl is not configured for a cluster"
  exit 1
fi
pass "kubectl is configured: $(kubectl config current-context)"

# Check KEDA CRDs
if ! kubectl get crd scaledobjects.keda.sh &>/dev/null; then
  fail "KEDA CRDs not found — run: bash scripts/install-keda.sh"
  exit 1
fi
pass "KEDA CRDs are installed"

# Check KEDA operator is running
KEDA_PODS=$(kubectl get pods -n keda -l app=keda-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$KEDA_PODS" -lt 1 ]; then
  fail "KEDA operator pod not running — run: bash scripts/install-keda.sh"
  exit 1
fi
pass "KEDA operator pod is running (${KEDA_PODS} pod(s))"

# Check ScaledObject exists
SCALED_OBJ=$(kubectl get scaledobject -n "$K8S_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SCALED_OBJ" -lt 1 ]; then
  fail "No ScaledObject found in ${K8S_NAMESPACE} — run: bash scripts/deploy-all-manifests.sh"
  exit 1
fi
pass "ScaledObject found in ${K8S_NAMESPACE}"

# Check ScaledObject is Ready
SO_READY=$(get_scaledobject_ready)
if [ "$SO_READY" = "True" ]; then
  pass "ScaledObject is Ready (KEDA is polling the queue)"
else
  echo -e "${YELLOW}⚠${NC}  ScaledObject status: ${SO_READY} (may take 30s to become Ready)"
fi

echo ""

# ─── Phase 2: Verify Scale-to-Zero Baseline ──────────────────────────────────
echo -e "${BOLD}Phase 2: Verify Scale-to-Zero Baseline${NC}"
echo "────────────────────────────────────────"

INITIAL_DEPTH=$(get_queue_depth)
INITIAL_PODS=$(get_total_pods)

echo -e "  Queue depth:   ${INITIAL_DEPTH} messages"
echo -e "  Running pods:  ${INITIAL_PODS} pods"

if [ "$INITIAL_DEPTH" -gt 0 ] && [ "$DRY_RUN" = false ]; then
  echo -e "${YELLOW}⚠${NC}  Queue is not empty. Purging ${INITIAL_DEPTH} messages..."
  aws sqs purge-queue --queue-url "$SQS_QUEUE_URL" --region "$AWS_REGION"
  echo "    Waiting 5s for purge..."
  sleep 5
  INITIAL_DEPTH=$(get_queue_depth)
fi

if [ "$INITIAL_DEPTH" -le 2 ]; then
  pass "Queue is at baseline depth (${INITIAL_DEPTH} messages)"
else
  fail "Queue has ${INITIAL_DEPTH} messages — baseline should be ~0"
fi

echo ""

# ─── Phase 3: Send Messages and Trigger Scale-Up ─────────────────────────────
echo -e "${BOLD}Phase 3: Send ${MESSAGE_COUNT} Messages → Trigger Scale-Up${NC}"
echo "────────────────────────────────────────"

EXPECTED_REPLICAS=$(( (MESSAGE_COUNT + 4) / 5 ))  # ceil(N/5)
if [ "$EXPECTED_REPLICAS" -gt 5 ]; then EXPECTED_REPLICAS=5; fi  # max replicas

echo -e "  Expected KEDA replicas: ${EXPECTED_REPLICAS} (ceil(${MESSAGE_COUNT}/5), max 5)"

if [ "$DRY_RUN" = false ]; then
  bash "${SCRIPT_DIR}/generate-messages.sh" --count "$MESSAGE_COUNT" > /dev/null
  echo -e "${GREEN}✔${NC}  Sent ${MESSAGE_COUNT} messages to SQS"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would send ${MESSAGE_COUNT} messages"
fi

# Wait for queue depth to reflect
sleep 5
POST_SEND_DEPTH=$(get_queue_depth)
if [ "$POST_SEND_DEPTH" -ge "$MESSAGE_COUNT" ]; then
  pass "Queue depth after send: ${POST_SEND_DEPTH} messages"
else
  fail "Expected ${MESSAGE_COUNT} messages, queue shows ${POST_SEND_DEPTH}"
fi

echo ""

# ─── Phase 4: Wait for KEDA Scale-Up ─────────────────────────────────────────
echo -e "${BOLD}Phase 4: Observe KEDA Scale-Up (timeout: ${SCALE_UP_TIMEOUT}s)${NC}"
echo "────────────────────────────────────────"

SCALE_START=$(date +%s)
PODS_APPEARED=false

while true; do
  CURRENT_PODS=$(get_total_pods)
  ELAPSED=$(( $(date +%s) - SCALE_START ))

  printf "\r  ⏳ [%3ds] Pods in %s: %d/%d expected" "$ELAPSED" "$K8S_NAMESPACE" "$CURRENT_PODS" "$EXPECTED_REPLICAS"

  if [ "$CURRENT_PODS" -ge "$EXPECTED_REPLICAS" ] && [ "$DRY_RUN" = false ]; then
    echo ""
    pass "KEDA scaled up to ${CURRENT_PODS} pod(s) in ${ELAPSED}s"
    PODS_APPEARED=true
    break
  fi

  if [ "$ELAPSED" -ge "$SCALE_UP_TIMEOUT" ]; then
    echo ""
    fail "Scale-up timeout: ${CURRENT_PODS}/${EXPECTED_REPLICAS} pods after ${SCALE_UP_TIMEOUT}s"
    break
  fi

  if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}⚠${NC}  [DRY RUN] Skipping scale-up wait"
    break
  fi

  sleep 10
done

echo ""

# ─── Phase 5: Wait for Queue to Drain ────────────────────────────────────────
if [ "$NO_WAIT" = false ] && [ "$DRY_RUN" = false ]; then
  echo -e "${BOLD}Phase 5: Observe Queue Drain (timeout: ${PROCESS_TIMEOUT}s)${NC}"
  echo "────────────────────────────────────────"

  DRAIN_START=$(date +%s)
  QUEUE_DRAINED=false

  while true; do
    DEPTH=$(get_queue_depth)
    ELAPSED=$(( $(date +%s) - DRAIN_START ))
    printf "\r  ⏳ [%3ds] Queue depth: %d messages remaining" "$ELAPSED" "$DEPTH"

    if [ "$DEPTH" -le 0 ]; then
      echo ""
      pass "Queue drained in ${ELAPSED}s — consumer pods processed all messages"
      QUEUE_DRAINED=true
      break
    fi

    if [ "$ELAPSED" -ge "$PROCESS_TIMEOUT" ]; then
      echo ""
      fail "Drain timeout: ${DEPTH} messages still in queue after ${PROCESS_TIMEOUT}s"
      break
    fi

    sleep 10
  done

  echo ""

  # ─── Phase 6: Observe Scale-to-Zero ─────────────────────────────────────────
  if [ "$QUEUE_DRAINED" = true ]; then
    echo -e "${BOLD}Phase 6: Observe Scale-to-Zero (timeout: ${SCALE_DOWN_TIMEOUT}s)${NC}"
    echo "────────────────────────────────────────"
    echo -e "  (KEDA cooldownPeriod=300s — expect pods to terminate after ~5 min)"

    SCALEDOWN_START=$(date +%s)

    while true; do
      CURRENT_PODS=$(get_total_pods)
      ELAPSED=$(( $(date +%s) - SCALEDOWN_START ))
      printf "\r  ⏳ [%3ds] Pods remaining: %d" "$ELAPSED" "$CURRENT_PODS"

      if [ "$CURRENT_PODS" -eq 0 ]; then
        echo ""
        pass "Scale-to-zero confirmed! All pods terminated in ${ELAPSED}s"
        break
      fi

      if [ "$ELAPSED" -ge "$SCALE_DOWN_TIMEOUT" ]; then
        echo ""
        fail "Scale-to-zero timeout: ${CURRENT_PODS} pod(s) still running after ${SCALE_DOWN_TIMEOUT}s"
        echo -e "       (Check ScaledObject cooldownPeriod in keda-scaled-object.yaml)"
        break
      fi

      sleep 15
    done
    echo ""
  fi
fi

# ─── Final Report ─────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
TOTAL_ELAPSED=$(( END_TIME - START_TIME ))

echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   E2E Test Results${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Total time: ${TOTAL_ELAPSED}s"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}  |  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  ✔ All E2E tests passed — KEDA autoscaling is working!${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}  ✘ ${FAIL_COUNT} test(s) failed — see details above${NC}"
  exit 1
fi
