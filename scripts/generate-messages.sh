#!/usr/bin/env bash
# =============================================================================
# generate-messages.sh
# Publishes test messages to the SQS queue to trigger KEDA autoscaling.
# This is the AWS port of generate-message.sh from the GCP reference repo.
#
# GCP Original (reference repo):
#   gcloud pubsub topics publish keda-demo-topic --message "message-$i"
#
# AWS Equivalent:
#   aws sqs send-message --queue-url $URL --message-body "message-$i"
#
# Usage:
#   bash scripts/generate-messages.sh              # Send 10 messages (default)
#   bash scripts/generate-messages.sh --count 50   # Send 50 messages
#   bash scripts/generate-messages.sh --count 1 --verbose
#   bash scripts/generate-messages.sh --check      # Just show queue depth
#
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

# ─── Defaults ─────────────────────────────────────────────────────────────────
MESSAGE_COUNT=10
VERBOSE=false
CHECK_ONLY=false
BATCH_SIZE=10    # SQS send-message-batch supports up to 10 messages per call

# ─── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --count|-n)   MESSAGE_COUNT="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=true;       shift   ;;
    --check|-c)   CHECK_ONLY=true;    shift   ;;
    --help|-h)
      echo "Usage: $0 [--count N] [--verbose] [--check]"
      echo "  --count N   Number of messages to send (default: 10)"
      echo "  --verbose   Print each message ID after send"
      echo "  --check     Only show current queue depth, don't send"
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

AWS_REGION="${AWS_REGION:-us-east-1}"
SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-keda-demo-queue}"

# ─── Resolve Queue URL ────────────────────────────────────────────────────────
if [ -n "${SQS_QUEUE_URL:-}" ] && [[ "$SQS_QUEUE_URL" != *"REPLACE"* ]]; then
  QUEUE_URL="$SQS_QUEUE_URL"
else
  echo -e "${YELLOW}⚠${NC}  SQS_QUEUE_URL not in .env — looking up from AWS..."
  if ! QUEUE_URL=$(aws sqs get-queue-url \
      --queue-name "$SQS_QUEUE_NAME" \
      --region "$AWS_REGION" \
      --query 'QueueUrl' \
      --output text 2>/dev/null); then
    echo -e "${RED}✘${NC}  Queue '${SQS_QUEUE_NAME}' not found in ${AWS_REGION}"
    echo -e "     Run first: bash scripts/setup-sqs.sh"
    exit 1
  fi
fi

# ─── Helper: Get Queue Depth ──────────────────────────────────────────────────
get_queue_depth() {
  aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --region "$AWS_REGION" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --output json 2>/dev/null
}

print_queue_status() {
  local attrs
  attrs=$(get_queue_depth)
  local visible
  local in_flight
  visible=$(echo "$attrs"   | grep -o '"ApproximateNumberOfMessages": "[^"]*"'          | cut -d'"' -f4)
  in_flight=$(echo "$attrs" | grep -o '"ApproximateNumberOfMessagesNotVisible": "[^"]*"' | cut -d'"' -f4)
  echo -e "  ${CYAN}Queue depth:${NC}  ${BOLD}${visible}${NC} visible  |  ${in_flight} in-flight (being processed)"
}

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   SQS Message Generator — KEDA Autoscaling Trigger    ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Queue:  ${QUEUE_URL}"
echo -e "  Region: ${AWS_REGION}"
echo ""

# ─── Check-Only Mode ──────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" = true ]; then
  echo -e "${BOLD}Current Queue Status:${NC}"
  print_queue_status
  echo ""
  exit 0
fi

# ─── Pre-send Queue Depth ─────────────────────────────────────────────────────
echo -e "${BOLD}Before sending:${NC}"
print_queue_status
echo ""

# ─── Send Messages ────────────────────────────────────────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SENT=0
FAILED=0

echo -e "${BOLD}Sending ${MESSAGE_COUNT} messages to SQS...${NC}"
echo -e "${CYAN}  (KEDA formula: replicas = ceil(${MESSAGE_COUNT} / QUEUE_LENGTH))${NC}"
echo ""

# Send in batches for efficiency (SQS batch API: up to 10 per call)
REMAINING=$MESSAGE_COUNT
BATCH_NUM=0

while [ "$REMAINING" -gt 0 ]; do
  # Calculate this batch size
  CURRENT_BATCH=$(( REMAINING < BATCH_SIZE ? REMAINING : BATCH_SIZE ))
  BATCH_NUM=$(( BATCH_NUM + 1 ))

  # Build batch entries JSON
  ENTRIES="["
  for i in $(seq 1 "$CURRENT_BATCH"); do
    MSG_NUM=$(( (BATCH_NUM - 1) * BATCH_SIZE + i ))
    MSG_BODY="keda-demo-message-${MSG_NUM} | batch=${BATCH_NUM} | ts=${TIMESTAMP} | total=${MESSAGE_COUNT}"
    ENTRY_ID="msg-${MSG_NUM}"
    ENTRIES="${ENTRIES}{\"Id\":\"${ENTRY_ID}\",\"MessageBody\":\"${MSG_BODY}\"},"
  done
  # Remove trailing comma and close array
  ENTRIES="${ENTRIES%,}]"

  # Send batch
  if RESULT=$(aws sqs send-message-batch \
      --queue-url "$QUEUE_URL" \
      --region "$AWS_REGION" \
      --entries "$ENTRIES" \
      --output json 2>&1); then

    # Count successes and failures in this batch
    BATCH_SUCCESS=$(echo "$RESULT" | grep -o '"Id": "msg-' | wc -l | tr -d ' ')
    BATCH_FAILED=$(echo "$RESULT"  | grep -c '"Failed"' || echo 0)

    SENT=$(( SENT + CURRENT_BATCH ))
    FAILED=$(( FAILED + BATCH_FAILED ))

    if [ "$VERBOSE" = true ]; then
      echo -e "  ${GREEN}✔${NC}  Batch ${BATCH_NUM}: sent ${CURRENT_BATCH} messages"
      echo "$RESULT" | grep -o '"MessageId": "[^"]*"' | while read -r mid; do
        echo -e "       └─ ${mid}"
      done
    else
      # Progress indicator
      PROGRESS=$(( SENT * 20 / MESSAGE_COUNT ))
      BAR=$(printf '█%.0s' $(seq 1 "$PROGRESS"))$(printf '░%.0s' $(seq 1 $(( 20 - PROGRESS ))))
      printf "\r  [%s] %d/%d sent" "$BAR" "$SENT" "$MESSAGE_COUNT"
    fi
  else
    echo -e "${RED}✘${NC}  Batch ${BATCH_NUM} failed: ${RESULT}"
    FAILED=$(( FAILED + CURRENT_BATCH ))
  fi

  REMAINING=$(( REMAINING - CURRENT_BATCH ))
done

echo ""
echo ""

# ─── Results ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}Results:${NC}"
echo -e "  ${GREEN}✔${NC}  Sent:   ${SENT} messages"
if [ "$FAILED" -gt 0 ]; then
  echo -e "  ${RED}✘${NC}  Failed: ${FAILED} messages"
fi

# Post-send queue depth
echo ""
echo -e "${BOLD}After sending:${NC}"
print_queue_status

# ─── KEDA Scaling Prediction ─────────────────────────────────────────────────
KEDA_QUEUE_LENGTH="${KEDA_QUEUE_LENGTH:-5}"
EXPECTED_REPLICAS=$(( (SENT + KEDA_QUEUE_LENGTH - 1) / KEDA_QUEUE_LENGTH ))
MAX_REPLICAS="${KEDA_MAX_REPLICA_COUNT:-5}"
if [ "$EXPECTED_REPLICAS" -gt "$MAX_REPLICAS" ]; then
  EXPECTED_REPLICAS=$MAX_REPLICAS
fi

echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   KEDA Scaling Prediction${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Formula:  ceil(${SENT} messages ÷ ${KEDA_QUEUE_LENGTH} per replica)"
echo -e "  Expected: ${BOLD}${EXPECTED_REPLICAS} replica(s)${NC}  (max: ${MAX_REPLICAS})"
echo -e "  Watch:    kubectl get hpa -n \${APP_NAMESPACE:-keda-demo} -w"
echo ""
echo -e "  Note: KEDA checks the queue every ${KEDA_POLLING_INTERVAL:-15}s."
echo -e "        Actual scale-up may take 15-30s to reflect."
echo ""
