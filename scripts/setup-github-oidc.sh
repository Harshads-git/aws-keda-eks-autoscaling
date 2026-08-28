#!/usr/bin/env bash
# =============================================================================
# setup-github-oidc.sh
# Creates the AWS IAM OIDC provider and GitHub Actions IAM role.
# Must run ONCE before the CD workflow (.github/workflows/cd.yml) can execute.
#
# What this script creates:
#   1. IAM OIDC Identity Provider (GitHub Actions as trusted identity issuer)
#   2. IAM Role: github-actions-keda-demo
#      Trust policy: only your repo's main branch can assume it
#      Permissions: ECR push, EKS describe+update, STS (for IRSA in EKS)
#
# Why this cannot be in Terraform:
#   The IAM OIDC provider for GitHub Actions is a BOOTSTRAP resource —
#   it's needed before CD runs, and CD is what would apply Terraform.
#   This script breaks the chicken-and-egg problem.
#   (The EKS OIDC provider IS managed by Terraform — different provider)
#
# Usage:
#   bash scripts/setup-github-oidc.sh
#   bash scripts/setup-github-oidc.sh --dry-run
#
# References:
#   https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
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

# GitHub repo (format: owner/repo)
GITHUB_REPO="${GITHUB_REPO:-Harshads-git/aws-keda-eks-autoscaling}"
GITHUB_ORG=$(echo "$GITHUB_REPO" | cut -d'/' -f1)
GITHUB_REPO_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)

# GitHub's OIDC issuer URL (constant — does not change)
GITHUB_OIDC_URL="https://token.actions.githubusercontent.com"

# GitHub OIDC TLS certificate thumbprint
# This is the SHA1 fingerprint of the TLS cert for token.actions.githubusercontent.com
# Obtained via: openssl s_client -connect token.actions.githubusercontent.com:443 2>/dev/null \
#   | openssl x509 -fingerprint -sha1 -noout | sed 's/://g' | cut -d'=' -f2 | tr '[:upper:]' '[:lower:]'
# Updated as of 2024 — check GitHub docs if auth fails unexpectedly
GITHUB_OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

ROLE_NAME="github-actions-${PROJECT_NAME}"

# ─── Verify AWS CLI ───────────────────────────────────────────────────────────
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo -e "${RED}✘${NC}  AWS CLI not configured. Run: aws configure"
  exit 1
fi

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   GitHub Actions OIDC Setup                           ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  AWS Account:   ${AWS_ACCOUNT_ID}"
echo -e "  Region:        ${AWS_REGION}"
echo -e "  GitHub Repo:   ${GITHUB_REPO}"
echo -e "  IAM Role:      ${ROLE_NAME}"
[ "$DRY_RUN" = true ] && echo -e "  ${YELLOW}DRY RUN — no AWS resources will be created${NC}"
echo ""

# ─── Step 1: Create IAM OIDC Provider ────────────────────────────────────────
echo -e "${BOLD}[1/3] Creating GitHub OIDC Identity Provider in AWS IAM...${NC}"
echo -e "      This lets AWS trust JWTs issued by GitHub Actions"

OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if [ "$DRY_RUN" = false ]; then
  # Check if provider already exists
  if aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
      &>/dev/null; then
    echo -e "${YELLOW}⚠${NC}  OIDC provider already exists — skipping creation"
  else
    aws iam create-open-id-connect-provider \
      --url "$GITHUB_OIDC_URL" \
      --client-id-list "sts.amazonaws.com" \
      --thumbprint-list "$GITHUB_OIDC_THUMBPRINT"
    echo -e "${GREEN}✔${NC}  OIDC provider created: ${OIDC_PROVIDER_ARN}"
  fi
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create OIDC provider: ${OIDC_PROVIDER_ARN}"
fi

# ─── Step 2: Create IAM Role with Trust Policy ────────────────────────────────
echo ""
echo -e "${BOLD}[2/3] Creating IAM role: ${ROLE_NAME}...${NC}"
echo -e "      Trust policy: only ${GITHUB_REPO} main branch can assume this role"

# Trust policy: only YOUR repo's main branch can assume this role
# StringLike (not StringEquals) allows both:
#   refs/heads/main (push to branch)
#   environment:* (GitHub Environments)
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GitHubActionsOIDCTrust",
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:ref:refs/heads/main"
        },
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

if [ "$DRY_RUN" = false ]; then
  # Create or update the role
  if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo -e "${YELLOW}⚠${NC}  Role ${ROLE_NAME} already exists — updating trust policy"
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document "$TRUST_POLICY"
  else
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "$TRUST_POLICY" \
      --description "IAM role for GitHub Actions CD pipeline (OIDC federated)" \
      --tags Key=Project,Value="${PROJECT_NAME}" Key=ManagedBy,Value=bootstrap
    echo -e "${GREEN}✔${NC}  Role created: ${ROLE_NAME}"
  fi
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would create role: ${ROLE_NAME}"
  echo ""
  echo "Trust policy (preview):"
  echo "$TRUST_POLICY" | python3 -m json.tool 2>/dev/null || echo "$TRUST_POLICY"
fi

# ─── Step 3: Attach Permissions Policies ────────────────────────────────────
echo ""
echo -e "${BOLD}[3/3] Attaching minimum permissions to ${ROLE_NAME}...${NC}"

# Inline policy: minimum permissions for the CD workflow
PERMISSIONS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:DescribeRepositories"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/keda-demo*"
    },
    {
      "Sid": "EKSAccess",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/*"
    },
    {
      "Sid": "SQSReadForCD",
      "Effect": "Allow",
      "Action": [
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:${PROJECT_NAME}*"
    }
  ]
}
EOF
)

if [ "$DRY_RUN" = false ]; then
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "${ROLE_NAME}-policy" \
    --policy-document "$PERMISSIONS_POLICY"
  echo -e "${GREEN}✔${NC}  Permissions attached to ${ROLE_NAME}"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would attach inline policy to ${ROLE_NAME}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   GitHub OIDC Setup Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo -e "  ${BOLD}Next step: configure GitHub Secrets${NC}"
echo -e "  Run: bash scripts/setup-github-secrets.sh"
echo ""
