#!/usr/bin/env bash
# =============================================================================
# check-prerequisites.sh
# Validates that all required tools are installed and meet minimum versions.
# Also verifies AWS CLI is configured correctly.
#
# Usage: bash scripts/check-prerequisites.sh
# =============================================================================

set -euo pipefail

# ─── Colour Codes ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0

# ─── Helper Functions ─────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}   AWS KEDA EKS — Prerequisites Checker                ${NC}"
  echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${BOLD}── $1 ──────────────────────────────────────────────────${NC}"
}

pass() {
  echo -e "  ${GREEN}✔${NC}  $1"
  ((PASS++))
}

fail() {
  echo -e "  ${RED}✘${NC}  $1"
  ((FAIL++))
}

warn() {
  echo -e "  ${YELLOW}⚠${NC}  $1"
  ((WARN++))
}

# Compare semantic versions: returns 0 if $1 >= $2
version_gte() {
  local installed
  local required
  installed=$(echo "$1" | sed 's/[^0-9.]//g' | cut -d. -f1-2)
  required=$(echo "$2" | cut -d. -f1-2)
  [ "$(printf '%s\n' "$required" "$installed" | sort -V | head -n1)" = "$required" ]
}

check_tool() {
  local tool=$1
  local min_version=$2
  local version_cmd=$3
  local install_hint=$4

  if ! command -v "$tool" &>/dev/null; then
    fail "${tool} — NOT FOUND  |  Install: ${install_hint}"
    return
  fi

  local installed_version
  installed_version=$(eval "$version_cmd" 2>/dev/null | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1)

  if [ -z "$installed_version" ]; then
    warn "${tool} — found but couldn't determine version"
    return
  fi

  if version_gte "$installed_version" "$min_version"; then
    pass "${tool} ${installed_version}  (required: >= ${min_version})"
  else
    fail "${tool} ${installed_version} — too old  (required: >= ${min_version})  |  ${install_hint}"
  fi
}

# ─── Main Logic ───────────────────────────────────────────────────────────────

print_header

# ── Section 1: Core Tools ─────────────────────────────────────────────────────
print_section "Core Tools"

check_tool "aws" "2.0" \
  "aws --version" \
  "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

check_tool "kubectl" "1.28" \
  "kubectl version --client --short 2>/dev/null || kubectl version --client" \
  "https://kubernetes.io/docs/tasks/tools/"

check_tool "helm" "3.0" \
  "helm version --short" \
  "https://helm.sh/docs/intro/install/"

check_tool "terraform" "1.5" \
  "terraform version" \
  "https://developer.hashicorp.com/terraform/install"

check_tool "docker" "24.0" \
  "docker --version" \
  "https://docs.docker.com/get-docker/"

check_tool "git" "2.30" \
  "git --version" \
  "https://git-scm.com/downloads"

# ── Section 2: Optional but Recommended ───────────────────────────────────────
print_section "Optional Tools"

if command -v gh &>/dev/null; then
  gh_version=$(gh --version | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)
  pass "gh (GitHub CLI) ${gh_version}"
else
  warn "gh (GitHub CLI) — not found  (optional but useful)  |  winget install GitHub.cli"
fi

if command -v jq &>/dev/null; then
  jq_version=$(jq --version | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1)
  pass "jq ${jq_version}  (JSON processor)"
else
  warn "jq — not found  (optional, used in scripts)  |  winget install jqlang.jq"
fi

if command -v python3 &>/dev/null; then
  py_version=$(python3 --version | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1)
  pass "python3 ${py_version}"
elif command -v python &>/dev/null; then
  py_version=$(python --version 2>&1 | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1)
  pass "python ${py_version}"
else
  warn "python3 — not found  |  https://www.python.org/downloads/"
fi

# ── Section 3: AWS CLI Configuration ──────────────────────────────────────────
print_section "AWS CLI Configuration"

if ! command -v aws &>/dev/null; then
  fail "AWS CLI not installed — skipping configuration checks"
else
  # Check credentials are configured
  if aws sts get-caller-identity &>/dev/null 2>&1; then
    identity=$(aws sts get-caller-identity --output json 2>/dev/null)
    account=$(echo "$identity" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
    arn=$(echo "$identity" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)
    region=$(aws configure get region 2>/dev/null || echo "NOT SET")

    pass "AWS credentials valid"
    pass "Account ID: ${account}"
    pass "Identity:   ${arn}"
    pass "Region:     ${region}"

    # Warn if using root account
    if echo "$arn" | grep -q ":root"; then
      warn "You are using the ROOT account — create an IAM user instead!"
      warn "See: docs/setup-guide.md → Section 2"
    fi

    # Warn if region is not set
    if [ "$region" = "NOT SET" ]; then
      warn "Default region not set — run: aws configure set region us-east-1"
    fi
  else
    fail "AWS credentials not configured or invalid"
    fail "Run: aws configure  (see docs/setup-guide.md → Section 5)"
  fi
fi

# ── Section 4: Project Environment ────────────────────────────────────────────
print_section "Project Environment"

# Check .env file exists
if [ -f ".env" ]; then
  pass ".env file found"

  # Check critical variables are filled in
  # shellcheck disable=SC1091
  source .env 2>/dev/null || true

  if [ "${AWS_ACCOUNT_ID:-}" = "<REPLACE_WITH_YOUR_12_DIGIT_AWS_ACCOUNT_ID>" ] || [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    warn "AWS_ACCOUNT_ID not set in .env — fill in your 12-digit account ID"
  else
    pass "AWS_ACCOUNT_ID is set"
  fi

  if [ "${AWS_REGION:-}" = "us-east-1" ]; then
    pass "AWS_REGION = us-east-1"
  elif [ -n "${AWS_REGION:-}" ]; then
    pass "AWS_REGION = ${AWS_REGION}"
  else
    warn "AWS_REGION not set in .env"
  fi

  if [ "${TF_STATE_BUCKET:-}" = "<REPLACE_WITH_UNIQUE_BUCKET_NAME>" ] || [ -z "${TF_STATE_BUCKET:-}" ]; then
    warn "TF_STATE_BUCKET not set — needed for Day 10 (Terraform backend)"
  else
    pass "TF_STATE_BUCKET = ${TF_STATE_BUCKET}"
  fi
else
  warn ".env file not found — copy and fill in: cp .env.example .env"
fi

# Check Git remote is set correctly
if git remote get-url origin &>/dev/null 2>&1; then
  remote_url=$(git remote get-url origin)
  pass "Git remote: ${remote_url}"
else
  warn "No git remote set — run: git remote add origin <your-repo-url>"
fi

# ── Section 5: Docker Daemon ───────────────────────────────────────────────────
print_section "Docker Daemon"

if command -v docker &>/dev/null; then
  if docker info &>/dev/null 2>&1; then
    pass "Docker daemon is running"
  else
    fail "Docker is installed but daemon is NOT running"
    fail "Start Docker Desktop or run: sudo systemctl start docker"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Results Summary${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}✔  Passed:   ${PASS}${NC}"
echo -e "  ${YELLOW}⚠  Warnings: ${WARN}${NC}"
echo -e "  ${RED}✘  Failed:   ${FAIL}${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}${BOLD}  ✘ Some prerequisites are missing. Fix the failures above before proceeding.${NC}"
  echo ""
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}  ⚠ Prerequisites met with warnings. Review them before Day 3.${NC}"
  echo ""
  exit 0
else
  echo -e "${GREEN}${BOLD}  ✔ All prerequisites satisfied! You are ready to proceed.${NC}"
  echo ""
  exit 0
fi
