#!/usr/bin/env bash
# =============================================================================
# scripts/health-check.sh — System Health Report Card
# =============================================================================
# Single command that checks all SmartScale AI components and prints
# a clear PASS/WARN/FAIL status for each one.
#
# Use before a demo, after a deployment, or as a periodic sanity check.
#
# Usage:
#   bash scripts/health-check.sh                  # Full check
#   bash scripts/health-check.sh --namespace prod  # Check prod namespace
#   bash scripts/health-check.sh --json            # Machine-readable output
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-keda-demo}"
JSON_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --json)         JSON_MODE=true; shift ;;
    *) shift ;;
  esac
done

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

PASS=0; WARN=0; FAIL=0
RESULTS=()

check() {
  local name="$1" status="$2" detail="$3"
  RESULTS+=("{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$detail\"}")
  case $status in
    PASS) PASS=$((PASS+1)); echo -e "  ${GREEN}✓ PASS${NC}  ${name} ${DIM}— ${detail}${NC}" ;;
    WARN) WARN=$((WARN+1)); echo -e "  ${YELLOW}⚠ WARN${NC}  ${name} ${DIM}— ${detail}${NC}" ;;
    FAIL) FAIL=$((FAIL+1)); echo -e "  ${RED}✗ FAIL${NC}  ${name} ${DIM}— ${detail}${NC}" ;;
  esac
}

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}SmartScale AI — System Health Report${NC}"
echo -e "${DIM}Namespace: ${NAMESPACE} | Time: $(date +%Y-%m-%dT%H:%M:%S)${NC}"
echo ""

# ─── 1. Kubernetes Cluster ────────────────────────────────────────────────────
echo -e "${BOLD}[1/6] Kubernetes Cluster${NC}"
if kubectl cluster-info &>/dev/null; then
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo 0)
  check "Cluster reachable" "PASS" "kubectl connected, ${node_count} Ready node(s)"
else
  check "Cluster reachable" "FAIL" "Cannot connect to Kubernetes cluster"
fi

# ─── 2. KEDA Operator ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/6] KEDA Operator${NC}"
keda_pods=$(kubectl get pods -n keda -l app=keda-operator --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [[ $keda_pods -ge 1 ]]; then
  check "KEDA Operator" "PASS" "${keda_pods} operator pod(s) Running"
else
  check "KEDA Operator" "FAIL" "No KEDA operator pods found in 'keda' namespace"
fi

keda_metrics=$(kubectl get pods -n keda -l app=keda-metrics-apiserver --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [[ $keda_metrics -ge 1 ]]; then
  check "KEDA Metrics Server" "PASS" "${keda_metrics} metrics-apiserver pod(s) Running"
else
  check "KEDA Metrics Server" "WARN" "Metrics apiserver not found — external metrics may not work"
fi

# ─── 3. ScaledObject ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/6] ScaledObject & HPA${NC}"
so_ready=$(kubectl get scaledobject -n "${NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$so_ready" = "True" ]]; then
  so_active=$(kubectl get scaledobject -n "${NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "Unknown")
  check "ScaledObject Ready" "PASS" "Ready=True, Active=${so_active}"
elif [[ -z "$so_ready" ]]; then
  check "ScaledObject Ready" "FAIL" "No ScaledObject found in namespace ${NAMESPACE}"
else
  check "ScaledObject Ready" "FAIL" "ScaledObject Ready=${so_ready} — check KEDA operator logs"
fi

hpa_count=$(kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ $hpa_count -ge 1 ]]; then
  check "HPA created by KEDA" "PASS" "${hpa_count} HPA(s) present"
else
  check "HPA created by KEDA" "WARN" "No HPA found — KEDA may not have created one yet"
fi

# ─── 4. Consumer Deployment ───────────────────────────────────────────────────
echo -e "\n${BOLD}[4/6] Consumer Deployment${NC}"
deploy_exists=$(kubectl get deployment keda-demo -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ $deploy_exists -ge 1 ]]; then
  replicas=$(kubectl get deployment keda-demo -n "${NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  ready=$(kubectl get deployment keda-demo -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [[ -z "$replicas" ]] && replicas=0
  [[ -z "$ready" ]] && ready=0
  if [[ $replicas -eq 0 ]]; then
    check "Consumer Deployment" "PASS" "Scaled to zero (idle, no cost)"
  elif [[ $ready -eq $replicas ]]; then
    check "Consumer Deployment" "PASS" "${ready}/${replicas} replicas Ready"
  else
    check "Consumer Deployment" "WARN" "${ready}/${replicas} Ready — some pods still starting"
  fi
else
  check "Consumer Deployment" "FAIL" "Deployment 'keda-demo' not found in ${NAMESPACE}"
fi

# ─── 5. SQS Queue (Local or AWS) ──────────────────────────────────────────────
echo -e "\n${BOLD}[5/6] SQS Queue${NC}"
sqs_pod=$(kubectl get pods -n "${NAMESPACE}" -l app=local-sqs --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [[ $sqs_pod -ge 1 ]]; then
  check "Local SQS (ElasticMQ)" "PASS" "${sqs_pod} local-sqs pod(s) Running"
elif command -v aws &>/dev/null; then
  queue_url=$(kubectl get configmap keda-demo-config -n "${NAMESPACE}" -o jsonpath='{.data.SQS_QUEUE_URL}' 2>/dev/null || echo "")
  if [[ -n "$queue_url" ]]; then
    depth=$(aws sqs get-queue-attributes --queue-url "$queue_url" \
      --attribute-names ApproximateNumberOfMessages \
      --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null || echo "error")
    if [[ "$depth" != "error" ]]; then
      check "AWS SQS Queue" "PASS" "Depth: ${depth} messages"
    else
      check "AWS SQS Queue" "FAIL" "Cannot query queue — check AWS credentials"
    fi
  else
    check "SQS Queue" "WARN" "No SQS_QUEUE_URL in ConfigMap and no local-sqs pod"
  fi
else
  check "SQS Queue" "WARN" "No local-sqs pod and aws CLI not installed"
fi

# ─── 6. Namespace Resources Summary ──────────────────────────────────────────
echo -e "\n${BOLD}[6/6] Namespace Resources Summary${NC}"
configmap=$(kubectl get configmap keda-demo-config -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ $configmap -ge 1 ]]; then
  check "ConfigMap (keda-demo-config)" "PASS" "Found"
else
  check "ConfigMap (keda-demo-config)" "FAIL" "Missing — consumer pods will crash without SQS_QUEUE_URL"
fi

secret=$(kubectl get secret -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "Secrets in namespace" "PASS" "${secret} secret(s) found"

# ─── Summary ──────────────────────────────────────────────────────────────────
TOTAL=$((PASS + WARN + FAIL))
echo ""
echo -e "${BOLD}───────────────────────────────────────${NC}"
echo -e "  ${GREEN}PASS: ${PASS}${NC}  ${YELLOW}WARN: ${WARN}${NC}  ${RED}FAIL: ${FAIL}${NC}  Total: ${TOTAL}"
echo -e "${BOLD}───────────────────────────────────────${NC}"

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "\n  ${GREEN}${BOLD}✓ All systems healthy — ready for demo!${NC}\n"
elif [[ $FAIL -eq 0 ]]; then
  echo -e "\n  ${YELLOW}${BOLD}⚠ System operational with warnings — review items above${NC}\n"
else
  echo -e "\n  ${RED}${BOLD}✗ System has failures — fix before demo${NC}\n"
fi

# ─── JSON Output ──────────────────────────────────────────────────────────────
if [[ "$JSON_MODE" = true ]]; then
  echo "{"
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"namespace\": \"${NAMESPACE}\","
  echo "  \"summary\": {\"pass\": ${PASS}, \"warn\": ${WARN}, \"fail\": ${FAIL}},"
  echo "  \"checks\": [$(IFS=,; echo "${RESULTS[*]}")]"
  echo "}"
fi

exit $FAIL
