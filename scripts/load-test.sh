#!/usr/bin/env bash
# =============================================================================
# scripts/load-test.sh — SQS Load Test with Scale-Up Timing Measurement
# =============================================================================
# Sends configurable batches of messages to SQS and measures how long KEDA
# takes to scale the consumer Deployment to the expected replica count.
#
# This answers the key performance question:
#   "How many seconds elapse between a traffic spike and pods being ready?"
#
# Reactive scaling timeline (what this script measures):
#   t=0    Messages sent to SQS
#   t=15   KEDA polls SQS (pollingInterval=15s): detects depth > 0
#   t=15   HPA updated: desiredReplicas = ceil(N / targetQueueLength)
#   t=20   Kubernetes schedules new pods
#   t=40   Pods pass startupProbe (5 attempts × 5s interval + initialDelay)
#   t=40   Pods start consuming → scale-up lag = 40s
#
# Usage:
#   bash scripts/load-test.sh                      # Default: 25 messages
#   bash scripts/load-test.sh --count 10            # 10 messages
#   bash scripts/load-test.sh --count 25 --rate 5   # 25 msgs, 5/second burst
#   bash scripts/load-test.sh --scenario ramp        # Gradual ramp: 5→25 msgs
#   bash scripts/load-test.sh --scenario burst       # Sudden burst: 0→25 msgs
#   bash scripts/load-test.sh --scenario wave        # Sine wave: repeating bursts
#   bash scripts/load-test.sh --dry-run              # Print plan without sending
#
# Prerequisites:
#   aws CLI configured (or QUEUE_URL + AWS_REGION set)
#   kubectl configured for keda-demo cluster
# =============================================================================

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-keda-demo}"
QUEUE_URL="${QUEUE_URL:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MESSAGE_COUNT="${MESSAGE_COUNT:-25}"
SEND_RATE="${SEND_RATE:-10}"        # Messages per second (max SQS batch=10)
SCENARIO="${SCENARIO:-burst}"       # burst | ramp | wave
TARGET_REPLICAS=0
DRY_RUN=false
RESULTS_FILE="/tmp/load-test-$(date +%Y%m%d-%H%M%S).json"

# ─── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --count)    MESSAGE_COUNT="$2"; shift 2 ;;
    --rate)     SEND_RATE="$2"; shift 2 ;;
    --scenario) SCENARIO="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --queue-url) QUEUE_URL="$2"; shift 2 ;;
    --help|-h)
      grep "^# " "${BASH_SOURCE[0]}" | head -30 | sed 's/^# //'
      exit 0 ;;
    *) shift ;;
  esac
done

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
metric()  { echo -e "${CYAN}  📊${NC} $*"; }
ok()      { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }

# ─── Helper Functions ──────────────────────────────────────────────────────────
get_queue_depth() {
  [[ -z "${QUEUE_URL}" ]] && echo "0" && return
  aws sqs get-queue-attributes \
    --queue-url "${QUEUE_URL}" \
    --attribute-names ApproximateNumberOfMessages \
    --region "${AWS_REGION}" \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text 2>/dev/null || echo "0"
}

get_pod_count() {
  kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_ready_pod_count() {
  kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null \
    | tr ' ' '\n' | grep -c "true" || echo "0"
}

send_batch() {
  local count="$1"
  local batch_size=10  # SQS max batch size
  local sent=0
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  while [[ $sent -lt $count ]]; do
    local this_batch=$((count - sent))
    [[ $this_batch -gt $batch_size ]] && this_batch=$batch_size

    # Build SendMessageBatch entries
    local entries=()
    for i in $(seq 1 "$this_batch"); do
      local id="msg-$((sent + i))"
      local body="{\"event\":\"load-test\",\"id\":\"${id}\",\"timestamp\":\"${timestamp}\",\"scenario\":\"${SCENARIO}\"}"
      entries+=("Id=${id},MessageBody=${body}")
    done

    if [[ "$DRY_RUN" = false ]]; then
      aws sqs send-message-batch \
        --queue-url "${QUEUE_URL}" \
        --entries "${entries[@]}" \
        --region "${AWS_REGION}" \
        --output text &>/dev/null
    fi

    sent=$((sent + this_batch))
  done
}

# ─── Scenarios ────────────────────────────────────────────────────────────────

scenario_burst() {
  # Sudden spike: all messages at once (worst-case for reactive scaling)
  log "Scenario: BURST — sending ${MESSAGE_COUNT} messages at once"
  echo ""
  local t_start
  t_start=$(date +%s)

  log "Sending ${MESSAGE_COUNT} messages..."
  [[ "$DRY_RUN" = false ]] && send_batch "$MESSAGE_COUNT"
  local t_sent
  t_sent=$(date +%s)
  ok "Messages sent in $((t_sent - t_start))s"

  TARGET_REPLICAS=$(python3 -c "import math; print(min(5, max(1, math.ceil(${MESSAGE_COUNT}/5))))")
  log "Expected replicas: ${TARGET_REPLICAS} (ceil(${MESSAGE_COUNT}/5), max 5)"

  measure_scale_up_time "$t_sent" "$TARGET_REPLICAS"
}

scenario_ramp() {
  # Gradual ramp: 5 → 10 → 15 → 20 → 25 messages (one batch every 30s)
  log "Scenario: RAMP — gradual increase over ~2 minutes"
  echo ""
  local t_start
  t_start=$(date +%s)
  local total_sent=0

  for batch_size in 5 5 5 5 5; do
    total_sent=$((total_sent + batch_size))
    log "Sending batch: +${batch_size} messages (total: ${total_sent})"
    [[ "$DRY_RUN" = false ]] && send_batch "$batch_size"
    local depth
    depth=$(get_queue_depth)
    local pods
    pods=$(get_pod_count)
    metric "Queue depth: ${depth} | Running pods: ${pods}"

    if [[ $total_sent -lt 25 ]]; then
      log "Waiting 30s before next batch..."
      sleep 30
    fi
  done

  TARGET_REPLICAS=5
  measure_scale_up_time "$t_start" "$TARGET_REPLICAS"
}

scenario_wave() {
  # Repeating waves: send 15 msgs → wait → send 15 msgs again (3 cycles)
  log "Scenario: WAVE — 3 cycles of 15-message bursts with 120s gaps"
  echo ""
  local t_start
  t_start=$(date +%s)

  for cycle in 1 2 3; do
    log "Wave ${cycle}/3: sending 15 messages..."
    [[ "$DRY_RUN" = false ]] && send_batch 15
    local t_sent
    t_sent=$(date +%s)
    metric "Wave ${cycle} sent at t=$((t_sent - t_start))s"

    # Record peak pods during this wave
    sleep 45  # Wait for scale-up
    local peak_pods
    peak_pods=$(get_pod_count)
    metric "Wave ${cycle} peak pods: ${peak_pods}"

    if [[ $cycle -lt 3 ]]; then
      log "Waiting 120s before next wave (queue drains, scale-down occurs)..."
      sleep 120
    fi
  done

  ok "Wave scenario complete (3 cycles)"
  TARGET_REPLICAS=3  # ceil(15/5)
}

# ─── Scale-Up Timing Measurement ─────────────────────────────────────────────
measure_scale_up_time() {
  local t_send_epoch="$1"
  local expected_replicas="$2"
  local t_first_pod=0
  local t_all_ready=0
  local timeout=180
  local interval=5
  local elapsed=0
  local last_pods=0

  echo ""
  log "Measuring scale-up time to ${expected_replicas} ready pods..."
  echo ""
  printf "  %-8s %-15s %-12s %-12s\n" "Elapsed" "Queue Depth" "Running" "Ready"
  printf "  %-8s %-15s %-12s %-12s\n" "-------" "-----------" "-------" "-----"

  while [[ $elapsed -lt $timeout ]]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))

    local depth running ready
    depth=$(get_queue_depth)
    running=$(get_pod_count)
    ready=$(get_ready_pod_count)

    printf "  %-8s %-15s %-12s %-12s\n" "${elapsed}s" "${depth}" "${running}" "${ready}"

    # Record time to first pod
    if [[ $t_first_pod -eq 0 && $running -ge 1 ]]; then
      t_first_pod=$elapsed
    fi

    # Record time to all pods ready
    if [[ $t_all_ready -eq 0 && $ready -ge $expected_replicas ]]; then
      t_all_ready=$elapsed
      break
    fi

    last_pods=$running
  done

  echo ""
  echo -e "${BOLD}═══════════════════════════════════════${NC}"
  echo -e "${BOLD}  Load Test Results — ${SCENARIO^^} Scenario${NC}"
  echo -e "${BOLD}═══════════════════════════════════════${NC}"
  metric "Messages sent:           ${MESSAGE_COUNT}"
  metric "Expected replicas:       ${expected_replicas}"
  metric "Time to first pod:       ${t_first_pod}s"
  metric "Time to all pods ready:  ${t_all_ready}s"

  if [[ $t_all_ready -gt 0 ]]; then
    ok "Scale-up complete in ${t_all_ready}s"
    if [[ $t_all_ready -le 45 ]]; then
      ok "SLO: PASS (target ≤ 45s from message send to pods ready)"
    else
      warn "SLO: MISS (target ≤ 45s — actual: ${t_all_ready}s)"
    fi
  else
    warn "Scale-up did not complete in ${timeout}s — check KEDA logs"
    echo "    kubectl logs -n keda -l app=keda-operator --tail=20"
  fi

  # Write JSON results
  cat > "${RESULTS_FILE}" <<EOF
{
  "scenario": "${SCENARIO}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "message_count": ${MESSAGE_COUNT},
  "expected_replicas": ${expected_replicas},
  "time_to_first_pod_s": ${t_first_pod},
  "time_to_all_ready_s": ${t_all_ready},
  "slo_target_s": 45,
  "slo_met": $([ $t_all_ready -le 45 ] && echo true || echo false)
}
EOF
  log "Results written to: ${RESULTS_FILE}"
}

# ─── Pre-flight Check ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}SmartScale AI — SQS Load Test${NC}"
echo -e "Namespace: ${NAMESPACE} | Scenario: ${SCENARIO} | Messages: ${MESSAGE_COUNT}"
echo -e "Dry-run: ${DRY_RUN}"
echo ""

if [[ -z "${QUEUE_URL}" ]]; then
  if kubectl get configmap keda-demo-config -n "${NAMESPACE}" &>/dev/null; then
    QUEUE_URL=$(kubectl get configmap keda-demo-config -n "${NAMESPACE}" \
      -o jsonpath='{.data.SQS_QUEUE_URL}' 2>/dev/null || echo "")
  fi
fi

[[ -z "${QUEUE_URL}" && "$DRY_RUN" = false ]] && {
  warn "QUEUE_URL not set. Export it: export QUEUE_URL=\$(terraform output -raw sqs_queue_url)"
}

# ─── Run Selected Scenario ────────────────────────────────────────────────────
case "${SCENARIO}" in
  burst)  scenario_burst ;;
  ramp)   scenario_ramp ;;
  wave)   scenario_wave ;;
  *) echo "Unknown scenario: ${SCENARIO}. Choose: burst | ramp | wave"; exit 1 ;;
esac
