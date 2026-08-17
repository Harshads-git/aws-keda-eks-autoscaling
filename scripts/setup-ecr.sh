#!/usr/bin/env bash
# =============================================================================
# setup-ecr.sh
# Creates the Amazon ECR (Elastic Container Registry) repository for the
# KEDA demo application Docker image.
#
# AWS equivalent of Google Artifact Registry / GCR setup.
#
# Features:
#   - Creates ECR repository with image scanning on push
#   - Sets lifecycle policy: keep last 10 tagged images, auto-expire untagged
#   - Outputs login command for docker authentication
#   - Idempotent: safe to run multiple times
#
# Usage:
#   bash scripts/setup-ecr.sh
#   bash scripts/setup-ecr.sh --dry-run
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Docker installed and running
#   - .env file with AWS_ACCOUNT_ID, AWS_REGION, ECR_REPO_NAME
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
  set -a; source "${PROJECT_ROOT}/.env"; set +a
  echo -e "${GREEN}✔${NC}  Loaded .env"
elif [ -f "${PROJECT_ROOT}/.env.example" ]; then
  set -a; source "${PROJECT_ROOT}/.env.example"; set +a
  echo -e "${YELLOW}⚠${NC}  Using .env.example defaults (copy to .env and fill in values)"
else
  echo -e "${RED}✘${NC}  No .env found. Run from project root."; exit 1
fi

# ─── Configuration ────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-keda-demo-app}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# ─── Verify AWS credentials and get Account ID ────────────────────────────────
echo ""
echo -e "${BOLD}[1/5] Verifying AWS credentials...${NC}"
if ! CALLER=$(aws sts get-caller-identity --output json 2>&1); then
  echo -e "${RED}✘${NC}  AWS credentials invalid. Run: aws configure"; exit 1
fi
AWS_ACCOUNT_ID=$(echo "$CALLER" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
echo -e "${GREEN}✔${NC}  Account: ${AWS_ACCOUNT_ID} | Region: ${AWS_REGION}"

ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   ECR Setup — Container Registry for KEDA Demo        ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Repository: ${ECR_REPO_NAME}"
echo -e "  Full URI:   ${ECR_REPO_URI}"
echo -e "  Dry run:    ${DRY_RUN}"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}${BOLD}DRY RUN MODE — no AWS resources will be created${NC}"
fi

# ─── Step 1: Create ECR Repository ───────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/5] Creating ECR repository: ${ECR_REPO_NAME}${NC}"

if [ "$DRY_RUN" = false ]; then
  # Check if repo already exists
  if aws ecr describe-repositories \
      --repository-names "$ECR_REPO_NAME" \
      --region "$AWS_REGION" \
      --output json &>/dev/null 2>&1; then
    echo -e "${YELLOW}⚠${NC}  Repository already exists: ${ECR_REPO_URI}"
  else
    aws ecr create-repository \
      --repository-name "$ECR_REPO_NAME" \
      --region "$AWS_REGION" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE \
      --output json > /dev/null

    echo -e "${GREEN}✔${NC}  Repository created: ${ECR_REPO_URI}"
    echo -e "${GREEN}✔${NC}  Image scanning on push: ENABLED"
    echo -e "${GREEN}✔${NC}  Tag mutability: MUTABLE (allows overwriting 'latest' tag)"
  fi
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create: ${ECR_REPO_URI}"
fi

# ─── Step 2: Apply Lifecycle Policy ──────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/5] Applying lifecycle policy...${NC}"
echo -e "  Rule 1: Keep last 10 tagged images (by imageCountMoreThan)"
echo -e "  Rule 2: Delete untagged images after 1 day (saves storage cost)"

LIFECYCLE_POLICY='{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 tagged images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["v", "sha-", "latest"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Delete untagged images after 1 day",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 1
      },
      "action": { "type": "expire" }
    }
  ]
}'

if [ "$DRY_RUN" = false ]; then
  aws ecr put-lifecycle-policy \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" \
    --lifecycle-policy-text "$LIFECYCLE_POLICY" \
    --output json > /dev/null
  echo -e "${GREEN}✔${NC}  Lifecycle policy applied"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would apply lifecycle policy"
fi

# ─── Step 3: Docker Login to ECR ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/5] Authenticating Docker with ECR...${NC}"
echo -e "  ECR tokens expire after 12 hours — run this step again if push fails"

if [ "$DRY_RUN" = false ]; then
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    aws ecr get-login-password \
      --region "$AWS_REGION" \
      | docker login \
          --username AWS \
          --password-stdin \
          "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" \
          2>&1 | grep -v "WARNING"
    echo -e "${GREEN}✔${NC}  Docker authenticated with ECR"
  else
    echo -e "${YELLOW}⚠${NC}  Docker not running — skipping authentication"
    echo -e "     To authenticate later, run:"
    echo -e "     aws ecr get-login-password --region ${AWS_REGION} | \\"
    echo -e "       docker login --username AWS --password-stdin \\"
    echo -e "       ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  fi
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would run: aws ecr get-login-password | docker login ..."
fi

# ─── Step 4: Update .env with ECR URI ────────────────────────────────────────
echo ""
echo -e "${BOLD}[5/5] Recording ECR URI in .env...${NC}"

if [ "$DRY_RUN" = false ] && [ -f "${PROJECT_ROOT}/.env" ]; then
  if grep -q "^ECR_REPO_URI=" "${PROJECT_ROOT}/.env"; then
    sed -i "s|^ECR_REPO_URI=.*|ECR_REPO_URI=${ECR_REPO_URI}|" "${PROJECT_ROOT}/.env"
    echo -e "${GREEN}✔${NC}  Updated ECR_REPO_URI in .env"
  else
    echo -e "${YELLOW}⚠${NC}  ECR_REPO_URI not found in .env — add manually:"
    echo -e "     ECR_REPO_URI=${ECR_REPO_URI}"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   ECR Setup Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Repository URI: ${ECR_REPO_URI}"
echo ""
echo -e "  Build & push commands:"
echo -e "  ${BLUE}# Build image${NC}"
echo -e "  docker build -t ${ECR_REPO_NAME}:latest ./application"
echo ""
echo -e "  ${BLUE}# Tag with git SHA (recommended for traceability)${NC}"
echo -e "  GIT_SHA=\$(git rev-parse --short HEAD)"
echo -e "  docker tag ${ECR_REPO_NAME}:latest ${ECR_REPO_URI}:\${GIT_SHA}"
echo -e "  docker tag ${ECR_REPO_NAME}:latest ${ECR_REPO_URI}:latest"
echo ""
echo -e "  ${BLUE}# Push both tags${NC}"
echo -e "  docker push ${ECR_REPO_URI}:\${GIT_SHA}"
echo -e "  docker push ${ECR_REPO_URI}:latest"
echo ""
echo -e "  Next: bash scripts/build-and-push.sh  (Day 7)"
echo ""
