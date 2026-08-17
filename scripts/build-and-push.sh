#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh
# Builds the Docker image and pushes it to Amazon ECR.
# This is the manual equivalent of what GitHub Actions CI does automatically
# (implemented on Day 22).
#
# Dual-tag strategy:
#   sha-<git-short-sha>  → immutable, used in kubectl set image for deployments
#   latest               → mutable, always points to the newest build
#
# Usage:
#   bash scripts/build-and-push.sh
#   bash scripts/build-and-push.sh --tag v1.0.0   # additional semantic tag
#   bash scripts/build-and-push.sh --no-push       # build only, skip ECR push
#   bash scripts/build-and-push.sh --dry-run
#
# Prerequisites:
#   - Docker running (docker info)
#   - AWS CLI configured with ECR push permissions
#   - ECR repository created (run scripts/setup-ecr.sh first)
#   - .env with ECR_REPO_URI set
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

# ─── Parse Arguments ──────────────────────────────────────────────────────────
DRY_RUN=false
NO_PUSH=false
EXTRA_TAG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)         DRY_RUN=true;       shift   ;;
    --no-push)         NO_PUSH=true;       shift   ;;
    --tag|-t)          EXTRA_TAG="$2";     shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--no-push] [--tag v1.0.0]"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Load Environment ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a; source "${PROJECT_ROOT}/.env"; set +a
elif [ -f "${PROJECT_ROOT}/.env.example" ]; then
  set -a; source "${PROJECT_ROOT}/.env.example"; set +a
fi

# ─── Resolve Git SHA and Tags ─────────────────────────────────────────────────
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "no-git")
GIT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Tag names
SHA_TAG="sha-${GIT_SHA}"
LATEST_TAG="latest"

# ─── Validate Required Config ─────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-keda-demo-app}"

# Derive ECR_REPO_URI from account ID if not set
if [ -z "${ECR_REPO_URI:-}" ] || [[ "${ECR_REPO_URI}" == *"REPLACE"* ]]; then
  echo -e "${YELLOW}⚠${NC}  ECR_REPO_URI not set — looking up from AWS..."
  if AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
    echo -e "${GREEN}✔${NC}  Derived ECR URI: ${ECR_REPO_URI}"
  else
    echo -e "${RED}✘${NC}  Cannot derive ECR_REPO_URI — AWS CLI not configured or ECR_REPO_URI not set"
    echo -e "     Run: aws configure  OR  set ECR_REPO_URI in .env"
    exit 1
  fi
fi

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}   Docker Build & ECR Push — KEDA Demo App             ${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Repository:  ${ECR_REPO_URI}"
echo -e "  Git SHA:     ${GIT_SHA}  (branch: ${GIT_BRANCH})"
echo -e "  Tags:        ${SHA_TAG}, ${LATEST_TAG}${EXTRA_TAG:+", $EXTRA_TAG"}"
echo -e "  Timestamp:   ${BUILD_TIMESTAMP}"
echo -e "  Dry run:     ${DRY_RUN} | No push: ${NO_PUSH}"
echo ""
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}${BOLD}DRY RUN — no Docker or AWS commands will execute${NC}"

# ─── Step 1: Verify Docker ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[1/5] Checking Docker daemon...${NC}"
if [ "$DRY_RUN" = false ]; then
  if ! docker info &>/dev/null 2>&1; then
    echo -e "${RED}✘${NC}  Docker daemon is not running"
    echo -e "     Start Docker Desktop or run: sudo systemctl start docker"
    exit 1
  fi
  DOCKER_VERSION=$(docker --version | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)
  echo -e "${GREEN}✔${NC}  Docker ${DOCKER_VERSION} is running"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would check Docker daemon"
fi

# ─── Step 2: Build Docker Image ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/5] Building Docker image...${NC}"
echo -e "  Context:    ${PROJECT_ROOT}/application"
echo -e "  Dockerfile: ${PROJECT_ROOT}/application/Dockerfile"
echo -e "  Strategy:   Multi-stage (builder + runtime, ~120MB final)"

LOCAL_IMAGE="${ECR_REPO_NAME}:${SHA_TAG}"

BUILD_ARGS=(
  "--file" "${PROJECT_ROOT}/application/Dockerfile"
  "--tag" "${LOCAL_IMAGE}"
  # Build args for OCI labels (visible in ECR image details)
  "--build-arg" "BUILD_DATE=${BUILD_TIMESTAMP}"
  "--build-arg" "GIT_SHA=${GIT_SHA}"
  "--build-arg" "GIT_BRANCH=${GIT_BRANCH}"
  # Cache optimization: use previous build's layers if available
  "--cache-from" "${ECR_REPO_URI}:latest"
  # Platform: explicitly target linux/amd64 for EKS x86 nodes
  "--platform" "linux/amd64"
  "${PROJECT_ROOT}/application"
)

if [ "$DRY_RUN" = false ]; then
  START_TIME=$(date +%s)

  # Pull existing latest for cache (fails silently if doesn't exist yet)
  echo -e "  ${CYAN}Pulling ${ECR_REPO_URI}:latest for layer cache...${NC}"
  docker pull "${ECR_REPO_URI}:latest" 2>/dev/null || \
    echo -e "  ${YELLOW}⚠${NC}  No existing image for cache (first build)"

  echo -e "  ${CYAN}Running: docker build ...${NC}"
  docker build "${BUILD_ARGS[@]}"

  END_TIME=$(date +%s)
  BUILD_DURATION=$(( END_TIME - START_TIME ))
  echo -e "${GREEN}✔${NC}  Build complete in ${BUILD_DURATION}s — image: ${LOCAL_IMAGE}"

  # Show image size
  IMAGE_SIZE=$(docker image inspect "${LOCAL_IMAGE}" --format='{{.Size}}' 2>/dev/null || echo 0)
  IMAGE_SIZE_MB=$(( IMAGE_SIZE / 1024 / 1024 ))
  echo -e "${GREEN}✔${NC}  Image size: ${IMAGE_SIZE_MB} MB"
else
  echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would run: docker build ${BUILD_ARGS[*]}"
fi

# ─── Step 3: Tag Images ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/5] Tagging images...${NC}"

TAG_PAIRS=(
  "${ECR_REPO_URI}:${SHA_TAG}"    # immutable SHA tag — used in kubectl set image
  "${ECR_REPO_URI}:${LATEST_TAG}" # mutable latest tag — convenience
)
[ -n "$EXTRA_TAG" ] && TAG_PAIRS+=("${ECR_REPO_URI}:${EXTRA_TAG}")

if [ "$DRY_RUN" = false ]; then
  for full_tag in "${TAG_PAIRS[@]}"; do
    docker tag "${LOCAL_IMAGE}" "${full_tag}"
    echo -e "${GREEN}✔${NC}  Tagged: ${full_tag}"
  done
else
  for full_tag in "${TAG_PAIRS[@]}"; do
    echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would tag: ${full_tag}"
  done
fi

# ─── Step 4: Authenticate Docker with ECR ────────────────────────────────────
if [ "$NO_PUSH" = false ] && [ "$DRY_RUN" = false ]; then
  echo ""
  echo -e "${BOLD}[4/5] Authenticating Docker with ECR...${NC}"
  echo -e "  (ECR tokens expire after 12 hours — this refreshes the token)"

  ECR_REGISTRY="${ECR_REPO_URI%%/*}"  # Extract just the registry hostname

  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login \
        --username AWS \
        --password-stdin \
        "$ECR_REGISTRY" \
        2>&1 | grep -v "WARNING" || true

  echo -e "${GREEN}✔${NC}  Authenticated with ECR: ${ECR_REGISTRY}"
else
  echo ""
  echo -e "${BOLD}[4/5] ECR Authentication...${NC}"
  [ "$NO_PUSH" = true ] && echo -e "${YELLOW}⚠${NC}  --no-push: skipping ECR authentication"
  [ "$DRY_RUN" = true ] && echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would authenticate with ECR"
fi

# ─── Step 5: Push to ECR ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[5/5] Pushing images to ECR...${NC}"

if [ "$NO_PUSH" = false ] && [ "$DRY_RUN" = false ]; then
  for full_tag in "${TAG_PAIRS[@]}"; do
    echo -e "  ${CYAN}Pushing: ${full_tag}${NC}"
    docker push "${full_tag}"
    echo -e "${GREEN}✔${NC}  Pushed: ${full_tag}"
  done
elif [ "$NO_PUSH" = true ]; then
  echo -e "${YELLOW}⚠${NC}  --no-push specified — skipping push"
else
  for full_tag in "${TAG_PAIRS[@]}"; do
    echo -e "${YELLOW}⚠${NC}  [DRY RUN] Would push: ${full_tag}"
  done
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Build Complete!${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Image SHA tag (use this in kubectl):  ${ECR_REPO_URI}:${SHA_TAG}"
echo -e "  Image latest tag:                     ${ECR_REPO_URI}:${LATEST_TAG}"
echo ""
echo -e "  Deploy to EKS:"
echo -e "  ${CYAN}kubectl set image deployment/keda-demo \\"
echo -e "    app=${ECR_REPO_URI}:${SHA_TAG} \\"
echo -e "    -n keda-demo${NC}"
echo ""
echo -e "  Or use the deploy script:"
echo -e "  ${CYAN}IMAGE_TAG=${SHA_TAG} bash scripts/deploy-all-manifests.sh${NC}"
echo ""

# Save the SHA tag to .env for deploy script to pick up
if [ "$DRY_RUN" = false ] && [ "$NO_PUSH" = false ] && [ -f "${PROJECT_ROOT}/.env" ]; then
  if grep -q "^IMAGE_TAG=" "${PROJECT_ROOT}/.env"; then
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${SHA_TAG}|" "${PROJECT_ROOT}/.env"
  fi
  echo -e "${GREEN}✔${NC}  Updated IMAGE_TAG=${SHA_TAG} in .env"
fi
