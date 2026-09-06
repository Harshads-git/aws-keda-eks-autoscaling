#!/usr/bin/env bash
# =============================================================================
# scripts/cost-estimate.sh
# Calculates estimated AWS cost for this project based on current configuration.
# Uses hard-coded pricing (us-east-1, Sept 2024) — check AWS pricing page for updates.
#
# Usage:
#   bash scripts/cost-estimate.sh
#   bash scripts/cost-estimate.sh --with-monitoring
#   bash scripts/cost-estimate.sh --spot
#   bash scripts/cost-estimate.sh --spot --with-monitoring
#
# Output: hourly + monthly cost breakdown by component
# Note: Actual costs may differ due to data transfer, API calls, storage I/O.
# =============================================================================

set -euo pipefail

# ─── Parse Arguments ──────────────────────────────────────────────────────────
WITH_MONITORING=false
USE_SPOT=false
HOURS_PER_MONTH=730  # AWS standard month = 730 hours

while [[ $# -gt 0 ]]; do
  case $1 in
    --with-monitoring) WITH_MONITORING=true; shift ;;
    --spot)            USE_SPOT=true;        shift ;;
    --help|-h)
      echo "Usage: $0 [--spot] [--with-monitoring]"
      echo "  --spot              Include Spot node group in estimate"
      echo "  --with-monitoring   Include Prometheus + Grafana resource costs"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Colour Codes ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Pricing (us-east-1, On-Demand, Sept 2024) ───────────────────────────────
# EKS
EKS_CONTROL_PLANE=0.10         # /hr (fixed, not eligible for Savings Plans)

# EC2 On-Demand
T3_MICRO_OD=0.0104             # /hr
T3_SMALL_OD=0.0230             # /hr
T3_MEDIUM_OD=0.0464            # /hr

# EC2 Spot (approximate — varies hourly)
T3_SMALL_SPOT=0.0041           # /hr (~82% discount from On-Demand)
T3A_SMALL_SPOT=0.0031          # /hr (~87% discount)
T3_MEDIUM_SPOT=0.0073          # /hr (~84% discount)

# Networking
NAT_GATEWAY=0.045              # /hr per gateway (we use 1)
NAT_DATA_PROCESS=0.045         # /GB (assume 0.5GB/hr SQS + ECR pulls = $0.023/hr)
NAT_DATA_EST=0.023             # /hr estimated

# SQS
SQS_PER_MILLION=0.40           # /million requests
# With 20s long polling: ~180 polls/hr/consumer × 5 consumers = 900 polls/hr
# = 21,600 polls/day = 648,000 polls/month ≈ 0.648M requests
SQS_EST_MONTHLY=0.26           # estimated monthly

# ECR
ECR_STORAGE=0.10               # /GB/month (assume ~500MB images = $0.05/month)
ECR_EST_MONTHLY=0.05

# Prometheus/Grafana (when enabled) — STORAGE cost (RAM is just node cost)
PROMETHEUS_STORAGE=0.10        # /GB/month EBS (10GB for 7-day retention = $1/month)
PROM_EST_MONTHLY=1.00

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}${BOLD}║  AWS Cost Estimate — KEDA EKS Demo (us-east-1)        ║${NC}"
echo -e "${BLUE}${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Spot nodes:   ${USE_SPOT}  |  Monitoring: ${WITH_MONITORING}"
echo -e "  ${YELLOW}Note: estimates based on Sept 2024 pricing, 730hr/month${NC}"
echo -e "  ${YELLOW}Check: https://aws.amazon.com/ec2/pricing/on-demand/${NC}"
echo ""

# ─── Helper Functions ─────────────────────────────────────────────────────────
monthly() {
  echo $(echo "$1 $HOURS_PER_MONTH" | awk '{printf "%.2f", $1 * $2}')
}

print_line() {
  printf "  %-40s %8s/hr    %8s/month\n" "$1" "\$$2" "\$$3"
}

# ─── Compute Cost Components ──────────────────────────────────────────────────
TOTAL_HOURLY=0
TOTAL_MONTHLY=0

echo -e "${BOLD}Component Cost Breakdown:${NC}"
echo -e "  ${CYAN}$(printf '%-40s %8s      %8s\n' 'Component' '$/hr' '$/month')${NC}"
echo -e "  $(printf '%.0s─' {1..70})"

# EKS Control Plane
EKS_MONTHLY=$(monthly $EKS_CONTROL_PLANE)
print_line "EKS Control Plane (managed)" "$EKS_CONTROL_PLANE" "$EKS_MONTHLY"
TOTAL_HOURLY=$(echo "$TOTAL_HOURLY + $EKS_CONTROL_PLANE" | bc)
TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $EKS_MONTHLY" | bc)

# On-Demand Node (system — always 1)
OD_NODE_COST=$T3_MICRO_OD
OD_NODE_LABEL="t3.micro On-Demand (1 system node)"
if [ "$USE_SPOT" = true ]; then
  OD_NODE_COST=$T3_SMALL_OD
  OD_NODE_LABEL="t3.small On-Demand (1 system node)"
fi
OD_NODE_MONTHLY=$(monthly $OD_NODE_COST)
print_line "$OD_NODE_LABEL" "$OD_NODE_COST" "$OD_NODE_MONTHLY"
TOTAL_HOURLY=$(echo "$TOTAL_HOURLY + $OD_NODE_COST" | bc)
TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $OD_NODE_MONTHLY" | bc)

# Spot Node Group (when enabled)
if [ "$USE_SPOT" = true ]; then
  SPOT_NODE_COST=$T3A_SMALL_SPOT
  SPOT_NODE_MONTHLY=$(monthly $SPOT_NODE_COST)
  print_line "t3a.small Spot (avg 1 node, consumer)" "$SPOT_NODE_COST" "$SPOT_NODE_MONTHLY"
  TOTAL_HOURLY=$(echo "$TOTAL_HOURLY + $SPOT_NODE_COST" | bc)
  TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $SPOT_NODE_MONTHLY" | bc)

  # Burst scenario (5 Spot nodes active)
  BURST_HOURLY=$(echo "5 * $T3A_SMALL_SPOT" | bc)
  BURST_MONTHLY=$(monthly $BURST_HOURLY)
  echo ""
  echo -e "  ${YELLOW}  * Burst (5 Spot nodes active): +\$$BURST_HOURLY/hr (+\$$BURST_MONTHLY/month)${NC}"
fi

# NAT Gateway
NAT_TOTAL=$(echo "$NAT_GATEWAY + $NAT_DATA_EST" | bc)
NAT_MONTHLY=$(monthly $NAT_TOTAL)
print_line "NAT Gateway + data transfer (~0.5GB/hr)" "$NAT_TOTAL" "$NAT_MONTHLY"
TOTAL_HOURLY=$(echo "$TOTAL_HOURLY + $NAT_TOTAL" | bc)
TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $NAT_MONTHLY" | bc)

# SQS
echo -e "  $(printf '%-40s %8s      %8s\n' 'SQS API calls (estimated)' '~$0.00' "~\$$SQS_EST_MONTHLY")"
TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $SQS_EST_MONTHLY" | bc)

# ECR
echo -e "  $(printf '%-40s %8s      %8s\n' 'ECR storage (~500MB)' '~$0.00' "~\$$ECR_EST_MONTHLY")"
TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $ECR_EST_MONTHLY" | bc)

# Prometheus/Grafana storage (when monitoring enabled)
if [ "$WITH_MONITORING" = true ]; then
  if [ "$USE_SPOT" = false ]; then
    echo -e ""
    echo -e "  ${YELLOW}⚠  Monitoring needs t3.small+ (add ~\$0.012/hr for larger node)${NC}"
    MONITORING_NODE_DELTA=$(echo "$T3_SMALL_OD - $T3_MICRO_OD" | bc)
    MONITORING_NODE_MONTHLY=$(monthly $MONITORING_NODE_DELTA)
    print_line "t3.small upgrade for monitoring" "$MONITORING_NODE_DELTA" "$MONITORING_NODE_MONTHLY"
    TOTAL_HOURLY=$(echo "$TOTAL_HOURLY + $MONITORING_NODE_DELTA" | bc)
    TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $MONITORING_NODE_MONTHLY" | bc)
  fi
  echo -e "  $(printf '%-40s %8s      %8s\n' 'Prometheus EBS storage (10GB, 7d)' '~$0.00' "~\$$PROM_EST_MONTHLY")"
  TOTAL_MONTHLY=$(echo "$TOTAL_MONTHLY + $PROM_EST_MONTHLY" | bc)
fi

# ─── Totals ───────────────────────────────────────────────────────────────────
echo -e "  $(printf '%.0s─' {1..70})"
printf "  ${BOLD}%-40s %8s/hr    %8s/month${NC}\n" "TOTAL (estimate)" "\$$TOTAL_HOURLY" "\$$TOTAL_MONTHLY"

# ─── Comparison (On-Demand vs Spot) ──────────────────────────────────────────
if [ "$USE_SPOT" = true ]; then
  echo ""
  echo -e "${BOLD}Comparison vs All On-Demand:${NC}"
  OD_TOTAL_HOURLY=$(echo "$EKS_CONTROL_PLANE + $T3_SMALL_OD + $T3_SMALL_OD + $NAT_TOTAL" | bc)
  OD_TOTAL_MONTHLY=$(monthly $OD_TOTAL_HOURLY)
  OD_TOTAL_MONTHLY=$(echo "$OD_TOTAL_MONTHLY + $SQS_EST_MONTHLY + $ECR_EST_MONTHLY" | bc)
  SAVING_MONTHLY=$(echo "$OD_TOTAL_MONTHLY - $TOTAL_MONTHLY" | bc)
  echo -e "  On-Demand equivalent:   \$$OD_TOTAL_MONTHLY/month"
  echo -e "  With Spot (this config): \$$TOTAL_MONTHLY/month"
  echo -e "  ${GREEN}Monthly saving:         \$$SAVING_MONTHLY${NC}"
fi

# ─── Cost Reduction Tips ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Cost Reduction Tips:${NC}"
echo -e "  1. ${CYAN}Destroy when not using${NC} (biggest saving):"
echo -e "     cd terraform && terraform destroy"
echo -e "     Saves: \$$EKS_CONTROL_PLANE/hr (\$$EKS_MONTHLY/month) for EKS alone"
echo ""
echo -e "  2. ${CYAN}Single AZ (dev only)${NC} — remove NAT Gateway with VPC endpoints:"
echo -e "     Add SQS, STS, ECR VPC endpoints → \$0.04/hr vs \$$NAT_GATEWAY/hr NAT"
echo -e "     Saves: ~\$$(echo "$NAT_GATEWAY * $HOURS_PER_MONTH * 0.9" | awk '{printf "%.2f", $1}')/month"
echo ""
echo -e "  3. ${CYAN}Scale Spot to 0 when idle${NC} (CA min_size=0 for Spot group):"
echo -e "     Add to terraform.tfvars: spot_min_size = 0"
echo -e "     Consumer nodes cost \$0/hr when queue is empty"
echo ""
echo -e "  4. ${CYAN}Savings Plans${NC} (for 3+ month projects):"
echo -e "     Compute Savings Plans: 66% off EC2 On-Demand (1-year commitment)"
echo -e "     Does NOT apply to EKS control plane (\$0.10/hr is fixed)"
echo ""
echo -e "  Check live Spot pricing:"
echo -e "  ${CYAN}aws ec2 describe-spot-price-history --instance-types t3a.small t3.small \\${NC}"
echo -e "  ${CYAN}    --product-descriptions Linux/UNIX --region us-east-1 \\${NC}"
echo -e "  ${CYAN}    --query 'SpotPriceHistory[0:5].{Type:InstanceType,Price:SpotPrice}'${NC}"
echo ""
