#!/usr/bin/env bash
# =============================================================================
# scripts/benchmark.sh — Processing Latency Benchmark via Prometheus Metrics
# =============================================================================
# Queries Prometheus to extract P50/P95/P99 message processing latency,
# throughput (messages/second), error rate, and KEDA scaling metrics.
#
# No messages are sent by this script — it reads existing metrics from
# the Prometheus endpoint exposed by consumer pods on port 8080.
#
# Metrics queried (all defined in application/app.py):
#   keda_demo_message_processing_duration_seconds  → P50/P95/P99 latency
#   keda_demo_messages_processed_total             → throughput
#   keda_demo_messages_failed_total                → error rate
#   keda_demo_sqs_poll_errors_total                → SQS API health
#   keda_demo_consumer_active                      → active pod count
#
# Usage:
#   # Query Prometheus via port-forward (most common)
#   kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
#   bash scripts/benchmark.sh
#
#   # Query Prometheus at a custom address
#   bash scripts/benchmark.sh --prometheus http://localhost:9090
#
#   # Snapshot metrics from a single pod's /metrics endpoint
#   bash scripts/benchmark.sh --pod-metrics
#
#   # Run benchmark comparison: before vs after a change
#   bash scripts/benchmark.sh --snapshot before
#   # (make the change)
#   bash scripts/benchmark.sh --snapshot after
#   bash scripts/benchmark.sh --compare
# =============================================================================

set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
NAMESPACE="${NAMESPACE:-keda-demo}"
SNAPSHOT_DIR="${HOME}/.keda-benchmark"
SNAPSHOT_NAME=""
COMPARE_MODE=false
POD_METRICS_MODE=false
DURATION="${DURATION:-5m}"   # Time window for rate queries

while [[ $# -gt 0 ]]; do
  case $1 in
    --prometheus)   PROMETHEUS_URL="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --snapshot)     SNAPSHOT_NAME="$2"; shift 2 ;;
    --compare)      COMPARE_MODE=true; shift ;;
    --pod-metrics)  POD_METRICS_MODE=true; shift ;;
    --duration)     DURATION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "${SNAPSHOT_DIR}"

# ─── Colours ──────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; BLUE='\033[0;34m'; NC='\033[0m'

header() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }
metric() { printf "  %-40s %s\n" "$1" "$2"; }
ok()     { echo -e "${GREEN}✓${NC} $*"; }
warn()   { echo -e "${YELLOW}⚠${NC} $*"; }
bad()    { echo -e "${RED}✗${NC} $*"; }

# ─── Prometheus Query Helper ──────────────────────────────────────────────────
prom_query() {
  local query="$1"
  local result
  result=$(curl -sf \
    "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${query}" \
    2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    val = results[0].get('value', [None, 'N/A'])[1]
    print(float(val) if val != 'N/A' else 'N/A')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
  echo "${result}"
}

format_latency() {
  local val="$1"
  [[ "$val" = "N/A" ]] && echo "N/A" && return
  python3 -c "
v = float('${val}')
if v < 0.001: print(f'{v*1000:.3f}μs')
elif v < 1: print(f'{v*1000:.1f}ms')
else: print(f'{v:.2f}s')
" 2>/dev/null || echo "${val}s"
}

format_rate() {
  local val="$1"
  [[ "$val" = "N/A" ]] && echo "N/A" && return
  python3 -c "print(f'{float(\"${val}\"):.3f}/s')" 2>/dev/null || echo "${val}/s"
}

# ─── Pod-Level Metrics (direct scrape, no Prometheus needed) ─────────────────
pod_metrics_mode() {
  header "Direct Pod Metrics Scrape"
  local pods
  pods=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=keda-demo \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  [[ -z "$pods" ]] && warn "No running consumer pods found in ${NAMESPACE}" && return

  for pod in $pods; do
    echo ""
    echo -e "  ${CYAN}Pod: ${pod}${NC}"
    kubectl exec -n "${NAMESPACE}" "${pod}" -- \
      curl -sf http://localhost:8080/metrics 2>/dev/null \
      | grep "^keda_demo_" \
      | grep -v "^#" \
      | sort \
      | sed 's/^/    /'
  done
}

# ─── Main Prometheus Benchmark ────────────────────────────────────────────────
run_benchmark() {
  echo ""
  echo -e "${BOLD}SmartScale AI — Processing Latency Benchmark${NC}"
  echo -e "Prometheus: ${PROMETHEUS_URL}"
  echo -e "Time window: last ${DURATION}"
  echo -e "Timestamp:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  # Check Prometheus reachability
  if ! curl -sf "${PROMETHEUS_URL}/-/healthy" &>/dev/null; then
    warn "Prometheus not reachable at ${PROMETHEUS_URL}"
    warn "Start port-forward: kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &"
    warn "Falling back to pod-level metrics..."
    pod_metrics_mode
    return
  fi

  # ── Processing Latency (Histogram quantiles) ─────────────────────────────
  header "Processing Latency"

  local p50 p95 p99
  p50=$(prom_query "histogram_quantile(0.50, rate(keda_demo_message_processing_duration_seconds_bucket[${DURATION}]))")
  p95=$(prom_query "histogram_quantile(0.95, rate(keda_demo_message_processing_duration_seconds_bucket[${DURATION}]))")
  p99=$(prom_query "histogram_quantile(0.99, rate(keda_demo_message_processing_duration_seconds_bucket[${DURATION}]))")

  metric "P50 (median) latency:" "$(format_latency $p50)"
  metric "P95 latency:" "$(format_latency $p95)"
  metric "P99 latency:" "$(format_latency $p99)"

  # SLO check: P99 ≤ 5s (KedaDemoSlowProcessing alert threshold)
  if [[ "$p99" != "N/A" ]]; then
    if python3 -c "exit(0 if float('${p99}') <= 5.0 else 1)" 2>/dev/null; then
      ok "P99 SLO: PASS (${p99}s ≤ 5.0s)"
    else
      bad "P99 SLO: MISS (${p99}s > 5.0s — KedaDemoSlowProcessing alert threshold)"
    fi
  fi

  # ── Throughput ────────────────────────────────────────────────────────────
  header "Throughput"

  local processed_rate failed_rate error_rate
  processed_rate=$(prom_query "rate(keda_demo_messages_processed_total[${DURATION}])")
  failed_rate=$(prom_query "rate(keda_demo_messages_failed_total[${DURATION}])")

  local total_rate
  total_rate=$(python3 -c "
p = '${processed_rate}'; f = '${failed_rate}'
if 'N/A' in [p, f]: print('N/A')
else: print(float(p) + float(f))
" 2>/dev/null || echo "N/A")

  metric "Messages processed/s:" "$(format_rate $processed_rate)"
  metric "Messages failed/s:" "$(format_rate $failed_rate)"
  metric "Total throughput/s:" "$(format_rate $total_rate)"

  # Error rate percentage
  if [[ "$total_rate" != "N/A" && "$failed_rate" != "N/A" ]]; then
    local err_pct
    err_pct=$(python3 -c "
t = float('${total_rate}'); f = float('${failed_rate}')
print(f'{(f/t*100):.2f}%' if t > 0 else '0.00%')
" 2>/dev/null || echo "N/A")
    metric "Error rate:" "$err_pct"

    if python3 -c "
t = float('${total_rate}'); f = float('${failed_rate}')
exit(0 if t == 0 or (f/t) < 0.01 else 1)
" 2>/dev/null; then
      ok "Error rate SLO: PASS (< 1% — KedaDemoHighFailureRate threshold)"
    else
      bad "Error rate SLO: MISS (≥ 1% — KedaDemoHighFailureRate alert would fire)"
    fi
  fi

  # ── SQS Health ────────────────────────────────────────────────────────────
  header "SQS API Health"
  local poll_errors
  poll_errors=$(prom_query "rate(keda_demo_sqs_poll_errors_total[${DURATION}])")
  metric "SQS poll errors/s:" "$(format_rate $poll_errors)"

  # ── KEDA Scaling Metrics ──────────────────────────────────────────────────
  header "KEDA & Scaling"
  local active_consumers desired_replicas
  active_consumers=$(prom_query "sum(keda_demo_consumer_active)")
  metric "Active consumer pods:" "${active_consumers}"

  # ── Summary ───────────────────────────────────────────────────────────────
  header "SLO Summary"
  echo ""
  printf "  %-35s %-12s %-12s %s\n" "Metric" "Actual" "Target" "Status"
  printf "  %-35s %-12s %-12s %s\n" "------" "------" "------" "------"
  printf "  %-35s %-12s %-12s %s\n" \
    "P99 processing latency" "$(format_latency $p99)" "≤ 5s" \
    "$(python3 -c "v='${p99}'; print('✓ PASS' if v!='N/A' and float(v)<=5 else '✗ MISS')" 2>/dev/null || echo '?')"
  printf "  %-35s %-12s %-12s %s\n" \
    "Error rate" "${err_pct:-N/A}" "< 1%" "—"
  printf "  %-35s %-12s %-12s %s\n" \
    "Scale-up time (see load-test.sh)" "—" "≤ 45s" "—"
  echo ""

  # Save snapshot if requested
  if [[ -n "${SNAPSHOT_NAME}" ]]; then
    local snap_file="${SNAPSHOT_DIR}/${SNAPSHOT_NAME}.json"
    cat > "${snap_file}" <<EOF
{
  "snapshot": "${SNAPSHOT_NAME}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "p50_s": ${p50:-null},
  "p95_s": ${p95:-null},
  "p99_s": ${p99:-null},
  "processed_rate": ${processed_rate:-null},
  "failed_rate": ${failed_rate:-null}
}
EOF
    ok "Snapshot '${SNAPSHOT_NAME}' saved to ${snap_file}"
  fi
}

# ─── Compare Snapshots ────────────────────────────────────────────────────────
compare_snapshots() {
  local before="${SNAPSHOT_DIR}/before.json"
  local after="${SNAPSHOT_DIR}/after.json"

  [[ ! -f "$before" ]] && warn "No 'before' snapshot. Run: bash benchmark.sh --snapshot before" && return
  [[ ! -f "$after" ]]  && warn "No 'after' snapshot. Run: bash benchmark.sh --snapshot after" && return

  header "Before vs After Comparison"
  python3 <<'PYEOF'
import json, sys

with open("${SNAPSHOT_DIR}/before.json") as f: b = json.load(f)
with open("${SNAPSHOT_DIR}/after.json") as f: a = json.load(f)

def delta(key):
    bv, av = b.get(key), a.get(key)
    if bv is None or av is None: return "N/A"
    d = av - bv
    pct = (d / bv * 100) if bv else 0
    arrow = "↑" if d > 0 else "↓"
    return f"{arrow} {abs(pct):.1f}%"

print(f"  {'Metric':<30} {'Before':<12} {'After':<12} Change")
print(f"  {'-'*30} {'-'*12} {'-'*12} ------")
for k, label in [('p50_s','P50 latency'),('p95_s','P95 latency'),('p99_s','P99 latency')]:
    bv = b.get(k); av = a.get(k)
    bfmt = f"{bv*1000:.1f}ms" if bv else "N/A"
    afmt = f"{av*1000:.1f}ms" if av else "N/A"
    print(f"  {label:<30} {bfmt:<12} {afmt:<12} {delta(k)}")
PYEOF
}

# ─── Run ──────────────────────────────────────────────────────────────────────
if [[ "$POD_METRICS_MODE" = true ]]; then
  pod_metrics_mode
elif [[ "$COMPARE_MODE" = true ]]; then
  compare_snapshots
else
  run_benchmark
fi
