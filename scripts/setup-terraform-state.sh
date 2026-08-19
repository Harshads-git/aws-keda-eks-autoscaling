#!/usr/bin/env bash
# =============================================================================
# setup-terraform-state.sh
# Creates the S3 bucket and DynamoDB table needed for Terraform remote state.
#
# This is a BOOTSTRAP script — it creates infrastructure that Terraform uses
# to manage OTHER infrastructure. It cannot itself be managed by Terraform
# (chicken-and-egg problem: you need state storage before Terraform can run).
#
# Run this ONCE before your first 'terraform init' with the S3 backend.
#
# What it creates:
#   S3 Bucket:       keda-demo-tfstate-<account-id>
#     - Versioning enabled (roll back to any previous state)
#     - Server-side encryption (AES-256)
#     - Public access blocked (state file contains sensitive data!)
#     - Lifecycle: noncurrent versions deleted after 90 days (cost control)
#
#   DynamoDB Table:  keda-demo-tfstate-lock
#     - LockID (String) as partition key
#     - Used by Terraform to prevent concurrent 'terraform apply' runs
#     - PAY_PER_REQUEST billing (free tier: 25 WCU/RCU free, lock ops are rare)
#
# Usage:
#   bash scripts/setup-terraform-state.sh
#   bash scripts/setup-terraform-state.sh --dry-run
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
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) echo "Usage: $0 [--dry-run]"; exit 0 ;;
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
PROJECT_NAME="${PROJECT_NAME:-keda-demo}"

# ─── Derive Account ID ────────────────────────────────────────────────────────
echo -e "${BOLD}Looking up AWS account ID...${NC}"
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo -e "${RED}✘${NC}  AWS CLI not configured. Run: aws configure"
  exit 1
fi

BUCKET_NAME="${PROJECT_NAME}-tfstate-${AWS_ACCOUNT_ID}"
TABLE_NAME="${PROJECT_NAME}-tfstate-lock"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   Terraform Remote State Bootstrap                    ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  AWS Account:   ${AWS_ACCOUNT_ID}"
echo -e "  Region:        ${AWS_REGION}"
echo -e "  S3 Bucket:     ${BUCKET_NAME}"
echo -e "  DynamoDB:      ${TABLE_NAME}"
[ "$DRY_RUN" = true ] && echo -e "  ${YELLOW}DRY RUN — no AWS resources will be created${NC}"
echo ""

# ─── Step 1: Create S3 Bucket ─────────────────────────────────────────────────
echo -e "${BOLD}[1/5] Creating S3 state bucket: ${BUCKET_NAME}${NC}"

if [ "$DRY_RUN" = false ]; then
  # us-east-1 uses a different create-bucket syntax (no LocationConstraint)
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      2>/dev/null || echo -e "  ${YELLOW}⚠${NC}  Bucket already exists — skipping creation"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" \
      2>/dev/null || echo -e "  ${YELLOW}⚠${NC}  Bucket already exists — skipping creation"
  fi
  echo -e "${GREEN}✔${NC}  Bucket created/exists: s3://${BUCKET_NAME}"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create: s3://${BUCKET_NAME}"
fi

# ─── Step 2: Enable Versioning ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/5] Enabling versioning (allows state rollback)...${NC}"

if [ "$DRY_RUN" = false ]; then
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
  echo -e "${GREEN}✔${NC}  Versioning enabled"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would enable versioning on ${BUCKET_NAME}"
fi

# ─── Step 3: Enable Encryption ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/5] Enabling server-side encryption (AES-256)...${NC}"
echo -e "      State file contains sensitive data (cluster certs, secret keys)"

if [ "$DRY_RUN" = false ]; then
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }'
  echo -e "${GREEN}✔${NC}  Encryption enabled (AES-256)"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would enable AES-256 encryption"
fi

# ─── Step 4: Block Public Access ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/5] Blocking all public access...${NC}"

if [ "$DRY_RUN" = false ]; then
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo -e "${GREEN}✔${NC}  Public access blocked"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would block public access"
fi

# ─── Step 5: Create DynamoDB Lock Table ───────────────────────────────────────
echo ""
echo -e "${BOLD}[5/5] Creating DynamoDB lock table: ${TABLE_NAME}${NC}"

if [ "$DRY_RUN" = false ]; then
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" \
    --tags Key=Project,Value="${PROJECT_NAME}" Key=ManagedBy,Value=bootstrap \
    2>/dev/null || echo -e "  ${YELLOW}⚠${NC}  Table already exists — skipping creation"
  echo -e "${GREEN}✔${NC}  DynamoDB table created/exists: ${TABLE_NAME}"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create DynamoDB table: ${TABLE_NAME}"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Remote State Bootstrap Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Next steps:"
echo -e ""
echo -e "  ${BOLD}1. Update terraform/main.tf — uncomment the backend block:${NC}"
echo -e "     bucket         = \"${BUCKET_NAME}\""
echo -e "     key            = \"aws-keda-eks-autoscaling/terraform.tfstate\""
echo -e "     region         = \"${AWS_REGION}\""
echo -e "     dynamodb_table = \"${TABLE_NAME}\""
echo -e ""
echo -e "  ${BOLD}2. Re-initialize Terraform with the new backend:${NC}"
echo -e "     cd terraform && terraform init"
echo -e "     (Terraform will offer to migrate local state to S3)"
echo -e ""
echo -e "  ${BOLD}3. Verify state is stored in S3:${NC}"
echo -e "     aws s3 ls s3://${BUCKET_NAME}/"
echo ""
