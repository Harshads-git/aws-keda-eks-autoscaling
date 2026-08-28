#!/usr/bin/env bash
# =============================================================================
# setup-github-secrets.sh
# Reads Terraform outputs and populates GitHub Actions secrets automatically.
# Eliminates manual copy-pasting of ARNs, URLs, and IDs into GitHub Settings.
#
# Secrets set (all 4 required by .github/workflows/cd.yml):
#   AWS_ACCOUNT_ID   → your AWS account ID
#   AWS_REGION       → us-east-1
#   EKS_CLUSTER_NAME → keda-demo-dev-cluster
#   SQS_QUEUE_URL    → https://sqs.us-east-1.amazonaws.com/<account>/<queue>
#
# Prerequisites:
#   1. GitHub CLI (gh) installed: https://cli.github.com
#   2. gh auth login (authenticate gh with your GitHub account)
#   3. terraform apply completed (so outputs are available)
#   4. setup-github-oidc.sh run (IAM role exists)
#
# Usage:
#   bash scripts/setup-github-secrets.sh
#   bash scripts/setup-github-secrets.sh --dry-run
#   bash scripts/setup-github-secrets.sh --verify  (check secrets are set)
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
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true;    shift ;;
    --verify)  VERIFY_ONLY=true; shift ;;
    --help|-h) echo "Usage: $0 [--dry-run] [--verify]"; exit 0 ;;
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

# ─── Check Prerequisites ─────────────────────────────────────────────────────
echo -e "${BOLD}Checking prerequisites...${NC}"

# Check gh CLI
if ! command -v gh &>/dev/null; then
  echo -e "${RED}✘${NC}  GitHub CLI (gh) not found."
  echo -e "     Install: https://cli.github.com/manual/installation"
  echo -e "     macOS:   brew install gh"
  echo -e "     Linux:   sudo apt install gh"
  exit 1
fi

# Check gh authentication
if ! gh auth status &>/dev/null; then
  echo -e "${RED}✘${NC}  GitHub CLI not authenticated."
  echo -e "     Run: gh auth login"
  exit 1
fi
echo -e "${GREEN}✔${NC}  GitHub CLI authenticated"

# Check AWS CLI
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo -e "${RED}✘${NC}  AWS CLI not configured. Run: aws configure"
  exit 1
fi
echo -e "${GREEN}✔${NC}  AWS CLI configured (account: ${AWS_ACCOUNT_ID})"

# Check Terraform outputs are available
if ! terraform -chdir="$TERRAFORM_DIR" output -raw cluster_name &>/dev/null; then
  echo -e "${RED}✘${NC}  Terraform outputs not available."
  echo -e "     Run: cd terraform && terraform apply"
  exit 1
fi
echo -e "${GREEN}✔${NC}  Terraform outputs available"

# ─── Detect GitHub Repo ───────────────────────────────────────────────────────
# Auto-detect from git remote (no hardcoding)
GITHUB_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || \
              git remote get-url origin 2>/dev/null | \
              sed 's|https://github.com/||; s|git@github.com:||; s|\.git$||')

if [ -z "$GITHUB_REPO" ]; then
  echo -e "${RED}✘${NC}  Could not detect GitHub repository."
  echo -e "     Set GITHUB_REPO env var: export GITHUB_REPO=Harshads-git/aws-keda-eks-autoscaling"
  exit 1
fi
echo -e "${GREEN}✔${NC}  GitHub repo: ${GITHUB_REPO}"

# ─── Verify Mode ─────────────────────────────────────────────────────────────
if [ "$VERIFY_ONLY" = true ]; then
  echo ""
  echo -e "${BOLD}Verifying GitHub Secrets are set...${NC}"
  echo -e "${YELLOW}Note: GitHub only shows secret NAMES (not values) for security${NC}"
  echo ""

  REQUIRED_SECRETS=("AWS_ACCOUNT_ID" "AWS_REGION" "EKS_CLUSTER_NAME" "SQS_QUEUE_URL")
  ALL_OK=true

  for secret in "${REQUIRED_SECRETS[@]}"; do
    if gh secret list --repo "$GITHUB_REPO" 2>/dev/null | grep -q "^${secret}"; then
      echo -e "${GREEN}✔${NC}  ${secret} is set"
    else
      echo -e "${RED}✘${NC}  ${secret} is NOT set"
      ALL_OK=false
    fi
  done

  echo ""
  if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}✔${NC}  All secrets are configured. CD workflow is ready to run."
  else
    echo -e "${RED}✘${NC}  Some secrets are missing. Run without --verify to set them."
    exit 1
  fi
  exit 0
fi

# ─── Read Values from Terraform Outputs ──────────────────────────────────────
echo ""
echo -e "${BOLD}Reading values from Terraform outputs...${NC}"

AWS_REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region 2>/dev/null || echo "us-east-1")
EKS_CLUSTER_NAME=$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_name)
SQS_QUEUE_URL=$(terraform -chdir="$TERRAFORM_DIR" output -raw sqs_queue_url)

echo -e "${GREEN}✔${NC}  AWS_ACCOUNT_ID = ${AWS_ACCOUNT_ID}"
echo -e "${GREEN}✔${NC}  AWS_REGION     = ${AWS_REGION}"
echo -e "${GREEN}✔${NC}  EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"
echo -e "${GREEN}✔${NC}  SQS_QUEUE_URL  = ${SQS_QUEUE_URL}"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   Setting GitHub Actions Secrets                       ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Repository: ${GITHUB_REPO}"
[ "$DRY_RUN" = true ] && echo -e "  ${YELLOW}DRY RUN — no secrets will be set${NC}"
echo ""

# ─── Set GitHub Secrets ───────────────────────────────────────────────────────
set_secret() {
  local name="$1"
  local value="$2"
  local display_value="$3"  # What to show in logs (may be masked)

  if [ "$DRY_RUN" = false ]; then
    echo "$value" | gh secret set "$name" --repo "$GITHUB_REPO" --body -
    echo -e "${GREEN}✔${NC}  Set ${name} = ${display_value}"
  else
    echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would set ${name} = ${display_value}"
  fi
}

set_secret "AWS_ACCOUNT_ID"   "$AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"
set_secret "AWS_REGION"       "$AWS_REGION"     "$AWS_REGION"
set_secret "EKS_CLUSTER_NAME" "$EKS_CLUSTER_NAME" "$EKS_CLUSTER_NAME"
set_secret "SQS_QUEUE_URL"    "$SQS_QUEUE_URL" "${SQS_QUEUE_URL:0:50}..."

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   GitHub Secrets Configured!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Verify secrets are set:${NC}"
echo -e "  bash scripts/setup-github-secrets.sh --verify"
echo ""
echo -e "  ${BOLD}Trigger CD workflow manually:${NC}"
echo -e "  gh workflow run cd.yml --repo ${GITHUB_REPO}"
echo ""
echo -e "  ${BOLD}View workflow runs:${NC}"
echo -e "  gh run list --repo ${GITHUB_REPO} --workflow=cd.yml"
echo ""
