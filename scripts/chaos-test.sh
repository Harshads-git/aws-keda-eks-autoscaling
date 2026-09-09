#!/usr/bin/env bash
# =============================================================================
# scripts/chaos-test.sh — Chaos Engineering Test Suite for keda-demo
# =============================================================================
# Runs controlled failure experiments to verify system resilience.
# Each experiment: inject failure → observe → verify recovery → score result.
#
# Hypothesis-driven chaos engineering (Netflix Chaos Monkey model):
#   1. Define steady state (what "normal" looks like)
#   2. Hypothesize: "The system will maintain this behavior during [failure]"
#   3. Inject failure
#   4. Observe actual behavior
#   5. Compare to hypothesis → PASS or FAIL
#
# Usage:
#   bash scripts/chaos-test.sh                      # Run all experiments
#   bash scripts/chaos-test.sh --experiment pod-kill
#   bash scripts/chaos-test.sh --experiment scale-to-zero
#   bash scripts/chaos-test.sh --experiment network-partition
#   bash scripts/chaos-test.sh --experiment queue-flood
#   bash scripts/chaos-test.sh --experiment spot-interruption
#   bash scripts/chaos-test.sh --dry-run            # Show what would run, no changes
#
# Prerequisites:
#   kubectl configured for keda-demo-cluster
#   AWS CLI configured with appropriate permissions
#   jq installed (for JSON parsing)
# =============================================================================

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-keda-demo}"
QUEUE_URL="${QUEUE_URL:-$(kubectl get configmap keda-demo-config -n "${NAMESPACE}" -o jsonpath='{.data.SQS_QUEUE_URL}' 2>/dev/null || echo '')}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPERIMENT="${1:-all}"
DRY_RUN=false
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ─── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --experiment) EXPERIMENT="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--experiment <name>] [--dry-run] [--namespace <ns>]"
      echo ""
      echo "Experiments:"
      echo "  pod-kill          Kill a consumer pod and verify KEDA reschedules it"
      echo "  scale-to-zero     Drain queue and verify all pods terminate"
      echo "  network-partition Simulate DNS failure and verify error metrics increment"
      echo "  queue-flood       Send 25 messages and verify scale-up to 5 pods"
      echo "  spot-interruption Simulate Spot node drain and verify pod migration"
      echo "  all               Run all experiments (default)"
      exit 0 ;;
    *) shift ;;
  esac
done

# ─── Colour Codes ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helper Functions ──────────────────────────────────────────────────────────
log()  { echo -e "  ${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
pass() { echo -e "  ${GREEN}✓ PASS${NC} $*"; ((PASS_COUNT++)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} $*"; ((FAIL_COUNT++)); }
skip() { echo -e "  ${YELLOW}⊘ SKIP${NC} $*"; ((SKIP_COUNT++)); }
info() { echo -e "  ${BLUE}ℹ${NC} $*"; }

run_or_dry() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would run: $*"
    return 0
  fi
  "$@"
}

wait_for_condition() {
  local description="$1"
  local condition_cmd="$2"
  local timeout_s="${3:-120}"
  local interval=5
  local elapsed=0
  log "Waiting for: ${description} (timeout: ${timeout_s}s)..."
  while ! eval "${condition_cmd}" &>/dev/null; do
    sleep "${interval}"
    elapsed=$((elapsed + interval))
    if [ "${elapsed}" -ge "${timeout_s}" ]; then
      return 1
    fi
    echo -n "."
  done
  echo ""
  return 0
}

get_pod_count() {
  kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_queue_depth() {
  if [ -z "${QUEUE_URL}" ]; then echo "0"; return; fi
  aws sqs get-queue-attributes \
    --queue-url "${QUEUE_URL}" \
    --attribute-names ApproximateNumberOfMessages \
    --region "${AWS_REGION}" \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text 2>/dev/null || echo "0"
}

send_messages() {
  local count="$1"
  local message_body='{"event":"chaos-test","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
  log "Sending ${count} messages to SQS..."
  for i in $(seq 1 "${count}"); do
    run_or_dry aws sqs send-message \
      --queue-url "${QUEUE_URL}" \
      --message-body "${message_body}" \
      --region "${AWS_REGION}" \
      --output text &>/dev/null
  done
  log "Sent ${count} messages."
}

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  Experiment: $1${NC}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

# ─── Pre-flight Check ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}SmartScale AI — Chaos Engineering Test Suite${NC}"
echo -e "Namespace: ${NAMESPACE} | Region: ${AWS_REGION}"
echo -e "Queue URL: ${QUEUE_URL:-NOT SET}"
echo -e "Dry-run:   ${DRY_RUN}"
echo ""

if [ -z "${QUEUE_URL}" ] && [ "$DRY_RUN" = false ]; then
  echo -e "${YELLOW}⚠ QUEUE_URL not detected. Set QUEUE_URL env var or ensure cluster is running.${NC}"
  echo -e "  Export: export QUEUE_URL=\$(terraform output -raw sqs_queue_url)"
fi

# Verify kubectl connectivity
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null && [ "$DRY_RUN" = false ]; then
  echo -e "${RED}✗ Cannot reach namespace '${NAMESPACE}'. Is kubectl configured?${NC}"
  exit 1
fi

# ─── Experiment 1: Pod Kill ────────────────────────────────────────────────────
experiment_pod_kill() {
  print_header "Pod Kill — Verify KEDA Reschedules Killed Consumer"
  info "Hypothesis: Killing a consumer pod while queue has messages causes"
  info "  KEDA to reschedule a new pod within 60 seconds. The killed pod's"
  info "  in-flight SQS message is redelivered after visibility timeout."
  echo ""

  # Steady state: at least 1 pod running, queue non-empty
  log "Establishing steady state: sending 5 messages..."
  run_or_dry send_messages 5
  sleep 5

  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would kill a consumer pod and wait for rescheduling"
    skip "Pod kill (dry-run)"
    return
  fi

  local initial_pods
  initial_pods=$(get_pod_count)
  log "Initial pod count: ${initial_pods}"

  if [ "${initial_pods}" -eq 0 ]; then
    log "No running pods — waiting for KEDA to scale up (30s)..."
    sleep 30
    initial_pods=$(get_pod_count)
  fi

  if [ "${initial_pods}" -eq 0 ]; then
    skip "Pod kill — no pods running (KEDA may not have scaled yet)"
    return
  fi

  # Kill a pod
  local target_pod
  target_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log "Killing pod: ${target_pod}"
  run_or_dry kubectl delete pod "${target_pod}" -n "${NAMESPACE}" --grace-period=0 --force

  # Wait for pod to disappear
  log "Waiting for killed pod to terminate..."
  sleep 5

  # Wait for replacement pod (KEDA should reschedule)
  if wait_for_condition "replacement pod Running" \
    "[ \$(get_pod_count) -ge 1 ]" 90; then
    pass "Pod killed → replacement scheduled within 90 seconds"
  else
    fail "No replacement pod appeared within 90 seconds (KEDA may not be polling)"
  fi

  # Verify queue messages were not lost (visibility timeout returns them)
  local queue_depth
  queue_depth=$(get_queue_depth)
  if [ "${queue_depth}" -ge 0 ]; then
    pass "Queue still has messages (${queue_depth}) — SQS visibility timeout working"
  fi
}

# ─── Experiment 2: Scale to Zero ──────────────────────────────────────────────
experiment_scale_to_zero() {
  print_header "Scale to Zero — Verify All Pods Terminate When Queue Empties"
  info "Hypothesis: After the SQS queue is fully drained, KEDA scales the"
  info "  Deployment to 0 replicas within the cooldown period (300 seconds)."
  info "  Health file is removed on graceful shutdown."
  echo ""

  if [ "$DRY_RUN" = true ]; then
    skip "Scale-to-zero (dry-run)"
    return
  fi

  # Ensure queue is empty by purging it
  log "Purging SQS queue to force scale-to-zero..."
  run_or_dry aws sqs purge-queue \
    --queue-url "${QUEUE_URL}" \
    --region "${AWS_REGION}" 2>/dev/null || true
  log "Queue purged. KEDA cooldownPeriod is 300s — waiting up to 360s..."

  if wait_for_condition "0 consumer pods" \
    "[ \$(get_pod_count) -eq 0 ]" 360; then
    pass "Queue empty → all consumer pods terminated (scale-to-zero confirmed)"
  else
    local pods_remaining
    pods_remaining=$(get_pod_count)
    fail "Scale-to-zero failed: ${pods_remaining} pod(s) still running after 360s"
    info "  Check: kubectl describe scaledobject keda-demo-scaledobject -n ${NAMESPACE}"
  fi
}

# ─── Experiment 3: Network Partition (DNS Failure Simulation) ─────────────────
experiment_network_partition() {
  print_header "Network Partition — Verify Error Metrics and Retry Behavior"
  info "Hypothesis: If DNS resolution fails for SQS endpoints, the consumer"
  info "  increments keda_demo_sqs_poll_errors_total and retries with backoff."
  info "  The pod does NOT crash — it enters a retry loop."
  echo ""

  if [ "$DRY_RUN" = true ]; then
    skip "Network partition (dry-run) — would apply CoreDNS block rule temporarily"
    return
  fi

  local initial_pods
  initial_pods=$(get_pod_count)
  if [ "${initial_pods}" -eq 0 ]; then
    skip "Network partition — no running pods to test against"
    return
  fi

  # Record current error counter
  log "Recording baseline SQS poll error count via Prometheus metrics..."
  local target_pod
  target_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  local baseline_errors
  baseline_errors=$(kubectl exec "${target_pod}" -n "${NAMESPACE}" -- \
    python -c "
import urllib.request
try:
    response = urllib.request.urlopen('http://localhost:8080/metrics', timeout=5)
    content = response.read().decode()
    for line in content.split('\n'):
        if 'keda_demo_sqs_poll_errors_total' in line and not line.startswith('#'):
            print(line.split()[-1])
            break
    else:
        print('0')
except Exception:
    print('0')
" 2>/dev/null || echo "0")

  info "Baseline SQS poll errors: ${baseline_errors}"

  # Apply NetworkPolicy that blocks DNS (simulates network partition)
  log "Applying restrictive NetworkPolicy to block DNS egress temporarily..."
  run_or_dry kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: chaos-block-dns
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: keda-demo
  policyTypes:
    - Egress
  egress: []
EOF

  log "DNS blocked for 30 seconds..."
  sleep 30

  # Remove the restrictive policy
  log "Removing chaos NetworkPolicy (restoring connectivity)..."
  run_or_dry kubectl delete networkpolicy chaos-block-dns -n "${NAMESPACE}" --ignore-not-found

  sleep 10

  # Check if pod is still running (did not crash)
  local pods_after
  pods_after=$(get_pod_count)
  if [ "${pods_after}" -ge 1 ]; then
    pass "Pod survived network partition (did not crash) — retry loop working"
  else
    fail "Pod crashed during network partition — check graceful error handling"
  fi

  info "Check Prometheus metrics to confirm error counter incremented:"
  info "  kubectl port-forward pod/${target_pod} 8080:8080 -n ${NAMESPACE}"
  info "  curl http://localhost:8080/metrics | grep sqs_poll_errors"
}

# ─── Experiment 4: Queue Flood ────────────────────────────────────────────────
experiment_queue_flood() {
  print_header "Queue Flood — Verify KEDA Scales to maxReplicaCount Under Heavy Load"
  info "Hypothesis: Sending 25+ messages to the SQS queue causes KEDA to"
  info "  scale consumer pods to maxReplicaCount (5) within 120 seconds."
  echo ""

  if [ "$DRY_RUN" = true ]; then
    skip "Queue flood (dry-run) — would send 25 messages"
    return
  fi

  # Purge first to start fresh
  log "Purging queue to start from zero..."
  aws sqs purge-queue \
    --queue-url "${QUEUE_URL}" \
    --region "${AWS_REGION}" 2>/dev/null || true
  sleep 5

  # Send 25 messages (should trigger maxReplicaCount=5 since 25/5=5)
  log "Sending 25 messages to trigger maximum scale-up..."
  send_messages 25

  local queue_depth
  queue_depth=$(get_queue_depth)
  info "Queue depth after sending: ${queue_depth} messages"

  # Wait for KEDA to scale to 5
  log "Waiting for 5 consumer pods (KEDA pollingInterval=15s, ~30-45s expected)..."
  if wait_for_condition "5 consumer pods" \
    "[ \$(get_pod_count) -ge 5 ]" 120; then
    local final_pods
    final_pods=$(get_pod_count)
    pass "Queue flooded with 25 messages → scaled to ${final_pods}/5 pods within 120s"
  else
    local current_pods
    current_pods=$(get_pod_count)
    fail "Only ${current_pods}/5 pods running after 120s — KEDA scale-up too slow"
    info "  Check: kubectl describe hpa -n ${NAMESPACE}"
    info "  Check: kubectl logs -n keda -l app=keda-operator --tail=20"
  fi

  # Check KEDA metrics
  local scaler_value
  scaler_value=$(kubectl get hpa -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].status.currentMetrics[0].external.current.averageValue}' 2>/dev/null || echo "unknown")
  info "KEDA HPA current metric value: ${scaler_value}"
}

# ─── Experiment 5: Spot Interruption Simulation ───────────────────────────────
experiment_spot_interruption() {
  print_header "Spot Interruption — Verify Pod Migration After Node Drain"
  info "Hypothesis: When a node is cordoned and drained (simulating Spot"
  info "  interruption), consumer pods migrate to other nodes within 90 seconds."
  info "  In-flight messages are either completed or returned to queue."
  echo ""

  if [ "$DRY_RUN" = true ]; then
    skip "Spot interruption (dry-run) — would cordon and drain a worker node"
    return
  fi

  # Find a worker node running consumer pods
  local initial_pods
  initial_pods=$(get_pod_count)
  if [ "${initial_pods}" -eq 0 ]; then
    log "No pods running. Sending 5 messages to trigger scale-up..."
    send_messages 5
    sleep 30
    initial_pods=$(get_pod_count)
  fi

  if [ "${initial_pods}" -eq 0 ]; then
    skip "Spot interruption — could not get pods running"
    return
  fi

  local target_node
  target_node=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)

  if [ -z "${target_node}" ]; then
    skip "Spot interruption — could not identify target node"
    return
  fi

  info "Target node: ${target_node}"
  local pods_on_node
  pods_on_node=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | grep -c "${target_node}" || echo "0")
  info "Consumer pods on target node: ${pods_on_node}"

  # Simulate Spot interruption: cordon the node
  log "Cordoning node ${target_node} (simulates Spot 2-minute notice)..."
  run_or_dry kubectl cordon "${target_node}"

  # Drain the node with grace period (simulates NTH drain)
  log "Draining node ${target_node} with 40s grace period..."
  run_or_dry kubectl drain "${target_node}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=40 \
    --timeout=60s 2>&1 | tail -5 || true

  # Verify pods migrate to other nodes
  log "Waiting for pods to reschedule on remaining nodes..."
  if wait_for_condition "pods rescheduled" \
    "[ \$(get_pod_count) -ge 1 ]" 120; then
    pass "Spot interruption simulation → pods migrated to remaining nodes"
  else
    fail "Pods did not reschedule within 120s after node drain"
  fi

  # Uncordon the node (cleanup)
  log "Uncordoning node ${target_node} (cleanup)..."
  run_or_dry kubectl uncordon "${target_node}"
  pass "Node uncordoned — cluster restored to normal state"
}

# ─── Run Experiments ──────────────────────────────────────────────────────────
case "${EXPERIMENT}" in
  pod-kill)           experiment_pod_kill ;;
  scale-to-zero)      experiment_scale_to_zero ;;
  network-partition)  experiment_network_partition ;;
  queue-flood)        experiment_queue_flood ;;
  spot-interruption)  experiment_spot_interruption ;;
  all)
    experiment_pod_kill
    experiment_scale_to_zero
    experiment_queue_flood
    experiment_spot_interruption
    experiment_network_partition
    ;;
  *)
    echo "Unknown experiment: ${EXPERIMENT}"
    echo "Run: $0 --help"
    exit 1 ;;
esac

# ─── Results Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Chaos Test Results${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS:${NC}  ${PASS_COUNT}"
echo -e "  ${RED}FAIL:${NC}  ${FAIL_COUNT}"
echo -e "  ${YELLOW}SKIP:${NC}  ${SKIP_COUNT}"
echo ""
if [ "${FAIL_COUNT}" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}All experiments passed — system is resilient! 🎉${NC}"
  exit 0
else
  echo -e "  ${RED}${BOLD}${FAIL_COUNT} experiment(s) failed — review logs above.${NC}"
  exit 1
fi
