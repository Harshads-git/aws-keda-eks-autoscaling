#!/usr/bin/env bash
# =============================================================================
# scripts/simulate-alert.sh — Trigger Alerts to Verify Notification Pipeline
# =============================================================================
# Simulates conditions that trigger each of the 7 PrometheusRule alerts
# so you can verify Alertmanager → Slack/Discord notifications work end-to-end.
#
# Usage:
#   bash scripts/simulate-alert.sh --alert all          # Trigger all 7 alerts
#   bash scripts/simulate-alert.sh --alert slow         # Trigger slow processing
#   bash scripts/simulate-alert.sh --alert error-rate   # Trigger high error rate
#   bash scripts/simulate-alert.sh --alert consumer-down # Trigger consumer down
#   bash scripts/simulate-alert.sh --alert dlq          # Trigger DLQ depth
#   bash scripts/simulate-alert.sh --alert keda-error   # Trigger KEDA error
#   bash scripts/simulate-alert.sh --alert scale-stuck  # Trigger stuck scaling
#   bash scripts/simulate-alert.sh --alert pod-restart  # Trigger pod restart loop
#   bash scripts/simulate-alert.sh --dry-run            # Print simulation plan only
#   bash scripts/simulate-alert.sh --cleanup            # Remove all simulations
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-keda-demo}"
ALERT="all"
DRY_RUN=false
CLEANUP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --alert|-a)    ALERT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --cleanup)     CLEANUP=true; shift ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
trigger() { echo -e "  ${RED}🔔 TRIGGER${NC} $*"; }
expect()  { echo -e "  ${YELLOW}📩 EXPECT${NC}  $*"; }
run()     { [[ "$DRY_RUN" = true ]] && echo -e "  ${DIM}[DRY-RUN] $*${NC}" || eval "$*"; }

# ─── Cleanup ──────────────────────────────────────────────────────────────────
if [[ "$CLEANUP" = true ]]; then
  log "Cleaning up all alert simulations..."
  kubectl delete pod alert-sim-pod -n "${NAMESPACE}" --ignore-not-found 2>/dev/null
  # Restore deployment if it was scaled down
  kubectl scale deployment keda-demo -n "${NAMESPACE}" --replicas=0 2>/dev/null || true
  echo -e "  ${GREEN}✓ Cleanup complete${NC}"
  exit 0
fi

echo ""
echo -e "${BOLD}${CYAN}SmartScale AI — Alert Simulation${NC}"
echo -e "${DIM}Namespace: ${NAMESPACE} | Alert: ${ALERT} | Dry-run: ${DRY_RUN}${NC}"
echo ""

# =============================================================================
# Alert 1: KedaDemoSlowProcessing
# PrometheusRule: histogram_quantile(0.99, ...) > 5 for 1m
# Simulation: send messages with a very slow processing delay
# =============================================================================
simulate_slow() {
  log "Alert: KedaDemoSlowProcessing (P99 > 5s for 1 minute)"
  trigger "Deploying a consumer pod with PROCESSING_DELAY_SECONDS=10"
  trigger "This makes each message take 10 seconds, pushing P99 above the 5s SLO"

  run "kubectl set env deployment/keda-demo -n ${NAMESPACE} PROCESSING_DELAY_SECONDS=10"

  expect "Alertmanager notification in ~2 minutes (1m for rule + 30s group_wait)"
  expect "Alert name: KedaDemoSlowProcessing"
  expect "Severity: warning"
  echo ""

  echo -e "  ${DIM}To restore: kubectl set env deployment/keda-demo -n ${NAMESPACE} PROCESSING_DELAY_SECONDS=2${NC}"
}

# =============================================================================
# Alert 2: KedaDemoHighFailureRate
# PrometheusRule: rate(failed) / rate(processed+failed) > 0.01 for 5m
# Simulation: send malformed messages that the consumer cannot parse
# =============================================================================
simulate_error_rate() {
  log "Alert: KedaDemoHighFailureRate (error rate > 1% for 5 minutes)"
  trigger "Sending 50 malformed messages (invalid JSON) to trigger parse failures"

  local pyCode
  pyCode=$(cat <<'PYEOF'
import boto3, os
sqs = boto3.client('sqs', region_name='us-east-1',
                   endpoint_url=os.environ.get('AWS_ENDPOINT_URL', 'http://local-sqs:9324'),
                   aws_access_key_id='dummy', aws_secret_access_key='dummy')
queue_url = os.environ.get('SQS_QUEUE_URL', 'http://local-sqs:9324/000000000000/keda-demo-queue')
for i in range(50):
    sqs.send_message(QueueUrl=queue_url, MessageBody='THIS IS NOT VALID JSON {{{')
print('Sent 50 malformed messages')
PYEOF
)
  local b64
  b64=$(echo "$pyCode" | base64 -w 0 2>/dev/null || echo "$pyCode" | base64 2>/dev/null)
  run "kubectl run alert-sim-pod --image=keda-demo-app:latest --restart=Never -n ${NAMESPACE} \
    --env='AWS_ENDPOINT_URL=http://local-sqs.${NAMESPACE}.svc.cluster.local:9324' \
    --env='SQS_QUEUE_URL=http://local-sqs.${NAMESPACE}.svc.cluster.local:9324/000000000000/keda-demo-queue' \
    -- python -c \"import base64; exec(base64.b64decode('${b64}').decode())\""

  expect "Alertmanager notification in ~6 minutes (5m for rule + 30s group_wait)"
  expect "Alert name: KedaDemoHighFailureRate"
  expect "Severity: warning"
  echo ""
}

# =============================================================================
# Alert 3: KedaDemoConsumerDown
# PrometheusRule: keda_demo_consumer_active == 0 for 5m (when expected > 0)
# Simulation: scale deployment to 0 while queue has messages
# =============================================================================
simulate_consumer_down() {
  log "Alert: KedaDemoConsumerDown (no consumer active when queue is not empty)"
  trigger "Pausing the ScaledObject so KEDA stops scaling"
  trigger "Then sending messages — queue fills up with no consumer pods"

  run "kubectl annotate scaledobject keda-demo-scaledobject -n ${NAMESPACE} \
    autoscaling.keda.sh/paused-replicas='0' --overwrite"

  expect "Alertmanager notification in ~6 minutes"
  expect "Alert name: KedaDemoConsumerDown"
  expect "Severity: critical"
  echo ""

  echo -e "  ${DIM}To restore: kubectl annotate scaledobject keda-demo-scaledobject -n ${NAMESPACE} autoscaling.keda.sh/paused-replicas- --overwrite${NC}"
}

# =============================================================================
# Alert 4: KedaDemoDLQDepthHigh
# PrometheusRule: sqs_dlq_approximate_number_of_messages > 0 for 5m
# Simulation: describe what would happen (DLQ is an AWS resource)
# =============================================================================
simulate_dlq() {
  log "Alert: KedaDemoDLQDepthHigh (messages landing in Dead Letter Queue)"
  trigger "In production: send messages that fail 3 times (maxReceiveCount=3)"
  trigger "After 3 failures, SQS automatically moves the message to the DLQ"
  trigger "Locally: this alert requires an actual DLQ (not available in ElasticMQ)"

  expect "Alertmanager notification when DLQ has messages for > 5 minutes"
  expect "Alert name: KedaDemoDLQDepthHigh"
  expect "Severity: critical"
  echo ""

  echo -e "  ${DIM}Note: DLQ depth can be simulated by pushing directly to a DLQ queue in AWS${NC}"
}

# =============================================================================
# Alert 5: KedaOperatorErrors
# PrometheusRule: rate(keda_operator_errors_total) > 0 for 5m
# Simulation: create a ScaledObject with an invalid trigger
# =============================================================================
simulate_keda_error() {
  log "Alert: KedaOperatorErrors (KEDA operator encountering errors)"
  trigger "Creating a ScaledObject with an invalid queue URL"
  trigger "KEDA will fail to connect and log errors"

  run "kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: invalid-scaledobject
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    name: keda-demo
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: 'http://nonexistent-host:9999/invalid-queue'
        queueLength: '5'
        awsRegion: 'us-east-1'
EOF"

  expect "Alertmanager notification in ~6 minutes"
  expect "Alert name: KedaOperatorErrors"
  expect "Severity: warning"
  echo ""

  echo -e "  ${DIM}To restore: kubectl delete scaledobject invalid-scaledobject -n ${NAMESPACE}${NC}"
}

# =============================================================================
# Alert 6: KedaDemoScalingStuck
# PrometheusRule: desired != actual for > 10m
# Simulation: set resource requests too high for the node to schedule
# =============================================================================
simulate_scale_stuck() {
  log "Alert: KedaDemoScalingStuck (desired replicas != actual for > 10 minutes)"
  trigger "Patching deployment with CPU request=100 (impossible to schedule)"
  trigger "Pods will be stuck in Pending state, desired != actual"

  run "kubectl patch deployment keda-demo -n ${NAMESPACE} --type=json \
    -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/cpu\",\"value\":\"100\"}]'"

  expect "Alertmanager notification in ~11 minutes (10m rule + 30s group_wait)"
  expect "Alert name: KedaDemoScalingStuck"
  expect "Severity: warning"
  echo ""

  echo -e "  ${DIM}To restore: kubectl patch deployment keda-demo -n ${NAMESPACE} --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/cpu\",\"value\":\"25m\"}]'${NC}"
}

# =============================================================================
# Alert 7: KedaDemoPodRestartLoop
# PrometheusRule: rate(restarts) > 0 for 5m
# Simulation: deploy a container with an invalid command (crash loop)
# =============================================================================
simulate_pod_restart() {
  log "Alert: KedaDemoPodRestartLoop (pods restarting repeatedly)"
  trigger "Patching deployment command to an invalid binary (causes CrashLoopBackOff)"

  run "kubectl patch deployment keda-demo -n ${NAMESPACE} --type=json \
    -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/command\",\"value\":[\"this-binary-does-not-exist\"]}]'"

  expect "Alertmanager notification in ~6 minutes"
  expect "Alert name: KedaDemoPodRestartLoop"
  expect "Severity: critical"
  echo ""

  echo -e "  ${DIM}To restore: kubectl patch deployment keda-demo -n ${NAMESPACE} --type=json -p='[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/command\"}]'${NC}"
}

# ─── Run Selected Alert(s) ────────────────────────────────────────────────────
case "$ALERT" in
  slow)          simulate_slow ;;
  error-rate)    simulate_error_rate ;;
  consumer-down) simulate_consumer_down ;;
  dlq)           simulate_dlq ;;
  keda-error)    simulate_keda_error ;;
  scale-stuck)   simulate_scale_stuck ;;
  pod-restart)   simulate_pod_restart ;;
  all)
    simulate_slow
    simulate_error_rate
    simulate_consumer_down
    simulate_dlq
    simulate_keda_error
    simulate_scale_stuck
    simulate_pod_restart
    ;;
  *)
    echo "Unknown alert: $ALERT"
    echo "Valid: slow | error-rate | consumer-down | dlq | keda-error | scale-stuck | pod-restart | all"
    exit 1
    ;;
esac

echo -e "${BOLD}${CYAN}Alert simulation complete.${NC}"
echo -e "${DIM}Run 'bash scripts/simulate-alert.sh --cleanup' to restore normal state.${NC}"
echo ""
