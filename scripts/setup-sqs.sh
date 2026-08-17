#!/usr/bin/env bash
# =============================================================================
# setup-sqs.sh
# Creates the Amazon SQS queue and Dead Letter Queue (DLQ) for the KEDA demo.
# This is the AWS equivalent of the GCP Pub/Sub topic + subscription setup.
#
# GCP Original:
#   gcloud pubsub topics create keda-demo-topic
#   gcloud pubsub subscriptions create keda-demo-topic-subscription --topic ...
#
# AWS Equivalent:
#   aws sqs create-queue (standard queue + DLQ + redrive policy)
#
# Usage:
#   bash scripts/setup-sqs.sh
#   bash scripts/setup-sqs.sh --dry-run   (prints what would be created)
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - .env file with AWS_ACCOUNT_ID, AWS_REGION, SQS_QUEUE_NAME, SQS_DLQ_NAME
# =============================================================================

set -euo pipefail

# ─── Colour Codes ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Parse Arguments ──────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

# ─── Load Environment ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "${PROJECT_ROOT}/.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "${PROJECT_ROOT}/.env"; set +a
  echo -e "${GREEN}✔${NC}  Loaded .env from ${PROJECT_ROOT}/.env"
elif [ -f "${PROJECT_ROOT}/.env.example" ]; then
  echo -e "${YELLOW}⚠${NC}  No .env found — using .env.example defaults"
  # shellcheck disable=SC1091
  set -a; source "${PROJECT_ROOT}/.env.example"; set +a
else
  echo -e "${RED}✘${NC}  No .env or .env.example found. Run from project root."
  exit 1
fi

# ─── Configuration (with defaults) ────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-keda-demo-queue}"
SQS_DLQ_NAME="${SQS_DLQ_NAME:-keda-demo-queue-dlq}"
SQS_MAX_RECEIVE_COUNT="${SQS_MAX_RECEIVE_COUNT:-3}"
SQS_VISIBILITY_TIMEOUT="${SQS_VISIBILITY_TIMEOUT:-30}"
SQS_MSG_RETENTION_SECONDS=86400          # 1 day (testing; max is 1,209,600 = 14 days)
SQS_RECEIVE_WAIT_TIME_SECONDS=20         # Long polling — reduces empty receives & cost

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   SQS Setup — KEDA Demo Queue Provisioning            ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Region:    ${AWS_REGION}"
echo -e "  Queue:     ${SQS_QUEUE_NAME}"
echo -e "  DLQ:       ${SQS_DLQ_NAME}"
echo -e "  Dry run:   ${DRY_RUN}"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}${BOLD}DRY RUN MODE — no AWS resources will be created${NC}"
  echo ""
fi

# ─── Verify AWS credentials ───────────────────────────────────────────────────
echo -e "${BOLD}[1/5] Verifying AWS credentials...${NC}"
if ! CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1); then
  echo -e "${RED}✘${NC}  AWS credentials not configured or invalid."
  echo -e "     Run: aws configure"
  echo -e "     See: docs/setup-guide.md"
  exit 1
fi
AWS_ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
CALLER_ARN=$(echo "$CALLER_IDENTITY"    | grep -o '"Arn": "[^"]*"'     | cut -d'"' -f4)
echo -e "${GREEN}✔${NC}  Account: ${AWS_ACCOUNT_ID} | Identity: ${CALLER_ARN}"

# ─── Step 1: Create Dead Letter Queue ────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/5] Creating Dead Letter Queue: ${SQS_DLQ_NAME}${NC}"
echo -e "  Purpose: Receives messages that fail processing ${SQS_MAX_RECEIVE_COUNT} times"

if [ "$DRY_RUN" = false ]; then
  # Check if DLQ already exists
  if DLQ_URL=$(aws sqs get-queue-url \
      --queue-name "$SQS_DLQ_NAME" \
      --region "$AWS_REGION" \
      --query 'QueueUrl' \
      --output text 2>/dev/null); then
    echo -e "${YELLOW}⚠${NC}  DLQ already exists: ${DLQ_URL}"
  else
    DLQ_URL=$(aws sqs create-queue \
      --queue-name "$SQS_DLQ_NAME" \
      --region "$AWS_REGION" \
      --attributes \
        MessageRetentionPeriod=1209600 \
        VisibilityTimeout="${SQS_VISIBILITY_TIMEOUT}" \
      --query 'QueueUrl' \
      --output text)
    echo -e "${GREEN}✔${NC}  DLQ created: ${DLQ_URL}"
  fi

  # Get DLQ ARN (needed for redrive policy)
  DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --region "$AWS_REGION" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)
  echo -e "${GREEN}✔${NC}  DLQ ARN:  ${DLQ_ARN}"
else
  DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:${SQS_DLQ_NAME}"
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create DLQ with ARN: ${DLQ_ARN}"
fi

# ─── Step 2: Create Main Queue with Redrive Policy ────────────────────────────
echo ""
echo -e "${BOLD}[3/5] Creating main queue: ${SQS_QUEUE_NAME}${NC}"
echo -e "  Messages failed ${SQS_MAX_RECEIVE_COUNT} times → auto-moved to DLQ"
echo -e "  Visibility timeout: ${SQS_VISIBILITY_TIMEOUT}s (message hidden during processing)"
echo -e "  Long polling wait:  ${SQS_RECEIVE_WAIT_TIME_SECONDS}s (reduces cost vs short polling)"

REDRIVE_POLICY="{\"deadLetterTargetArn\":\"${DLQ_ARN}\",\"maxReceiveCount\":\"${SQS_MAX_RECEIVE_COUNT}\"}"

if [ "$DRY_RUN" = false ]; then
  # Check if main queue already exists
  if QUEUE_URL=$(aws sqs get-queue-url \
      --queue-name "$SQS_QUEUE_NAME" \
      --region "$AWS_REGION" \
      --query 'QueueUrl' \
      --output text 2>/dev/null); then
    echo -e "${YELLOW}⚠${NC}  Queue already exists: ${QUEUE_URL}"
    echo -e "     Updating redrive policy..."
    aws sqs set-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --region "$AWS_REGION" \
      --attributes \
        "RedrivePolicy=${REDRIVE_POLICY}" \
        "VisibilityTimeout=${SQS_VISIBILITY_TIMEOUT}" \
        "ReceiveMessageWaitTimeSeconds=${SQS_RECEIVE_WAIT_TIME_SECONDS}" \
        "MessageRetentionPeriod=${SQS_MSG_RETENTION_SECONDS}"
    echo -e "${GREEN}✔${NC}  Queue attributes updated"
  else
    QUEUE_URL=$(aws sqs create-queue \
      --queue-name "$SQS_QUEUE_NAME" \
      --region "$AWS_REGION" \
      --attributes \
        "VisibilityTimeout=${SQS_VISIBILITY_TIMEOUT}" \
        "ReceiveMessageWaitTimeSeconds=${SQS_RECEIVE_WAIT_TIME_SECONDS}" \
        "MessageRetentionPeriod=${SQS_MSG_RETENTION_SECONDS}" \
        "RedrivePolicy=${REDRIVE_POLICY}" \
      --query 'QueueUrl' \
      --output text)
    echo -e "${GREEN}✔${NC}  Queue created: ${QUEUE_URL}"
  fi
else
  QUEUE_URL="https://sqs.${AWS_REGION}.amazonaws.com/${AWS_ACCOUNT_ID}/${SQS_QUEUE_NAME}"
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create queue: ${QUEUE_URL}"
fi

# ─── Step 3: Verify Queue Attributes ─────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/5] Verifying queue configuration...${NC}"

if [ "$DRY_RUN" = false ]; then
  ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --region "$AWS_REGION" \
    --attribute-names All \
    --output json)

  QUEUE_ARN=$(echo "$ATTRS"  | grep -o '"QueueArn": "[^"]*"'          | cut -d'"' -f4)
  VIS_T=$(echo "$ATTRS"      | grep -o '"VisibilityTimeout": "[^"]*"' | cut -d'"' -f4)
  WAIT_T=$(echo "$ATTRS"     | grep -o '"ReceiveMessageWaitTimeSeconds": "[^"]*"' | cut -d'"' -f4)

  echo -e "${GREEN}✔${NC}  Queue ARN:          ${QUEUE_ARN}"
  echo -e "${GREEN}✔${NC}  Visibility Timeout: ${VIS_T}s"
  echo -e "${GREEN}✔${NC}  Long Poll Wait:     ${WAIT_T}s"
  echo -e "${GREEN}✔${NC}  Redrive Policy:     max ${SQS_MAX_RECEIVE_COUNT} receives → DLQ"
fi

# ─── Step 4: Update .env with Queue URLs ─────────────────────────────────────
echo ""
echo -e "${BOLD}[5/5] Recording queue URLs...${NC}"

if [ "$DRY_RUN" = false ] && [ -f "${PROJECT_ROOT}/.env" ]; then
  # Update SQS_QUEUE_URL in .env
  if grep -q "^SQS_QUEUE_URL=" "${PROJECT_ROOT}/.env"; then
    sed -i "s|^SQS_QUEUE_URL=.*|SQS_QUEUE_URL=${QUEUE_URL}|" "${PROJECT_ROOT}/.env"
  fi
  # Update SQS_DLQ_URL in .env
  if grep -q "^SQS_DLQ_URL=" "${PROJECT_ROOT}/.env"; then
    sed -i "s|^SQS_DLQ_URL=.*|SQS_DLQ_URL=${DLQ_URL}|" "${PROJECT_ROOT}/.env"
  fi
  echo -e "${GREEN}✔${NC}  Updated .env with queue URLs"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Setup Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Main Queue URL: ${QUEUE_URL:-[dry run]}"
echo -e "  DLQ URL:        ${DLQ_URL:-[dry run]}"
echo ""
echo -e "  Next steps:"
echo -e "  1. Test with: bash scripts/generate-messages.sh"
echo -e "  2. Verify:    aws sqs get-queue-attributes --queue-url ${QUEUE_URL:-<url>} \\"
echo -e "                  --attribute-names ApproximateNumberOfMessages"
echo -e "  3. Continue:  Day 4 — ECR repository setup"
echo ""
