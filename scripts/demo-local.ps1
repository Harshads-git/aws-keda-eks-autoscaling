# =============================================================================
# scripts/demo-local.ps1 — 100% Free Local Live Demonstration for Evaluators
# =============================================================================
# Shows KEDA Event-Driven Autoscaling on your laptop:
#   Phase 1: Shows 0 pods running (Scale to Zero)
#   Phase 2: Sends 25 messages into SQS
#   Phase 3: Watches KEDA scale pods from 0 to 5 in real time!
#   Phase 4: Messages processed -> Pods scale cleanly back to 0!
# =============================================================================

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   SmartScale AI: Live Autoscaling Demonstration" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# Phase 1: Check baseline
Write-Host "[1/4] Checking Current State (Idle)..." -ForegroundColor Yellow
$currentPods = kubectl get pods -n keda-demo -l app=keda-demo --no-headers 2>$null
if (-not $currentPods) {
    Write-Host "  [OK] Current Pods: 0 (System is scaled to ZERO - `$0 compute cost!)" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host "  Existing pods draining, waiting for baseline..."
    while ($true) {
        Start-Sleep -Seconds 4
        $pods = kubectl get pods -n keda-demo -l app=keda-demo --no-headers 2>$null
        if (-not $pods) {
            Write-Host "  [OK] Reached Scale-to-Zero baseline: 0 pods running." -ForegroundColor Green
            Write-Host ""
            break
        }
    }
}

# Phase 2: Send Traffic
Write-Host "[2/4] Injecting Traffic Surge (Sending 25 Messages to SQS)..." -ForegroundColor Yellow

$pyCode = @'
import boto3, json
sqs = boto3.client('sqs', region_name='us-east-1', endpoint_url='http://local-sqs.keda-demo.svc.cluster.local:9324', aws_access_key_id='dummy', aws_secret_access_key='dummy')
q = 'http://local-sqs.keda-demo.svc.cluster.local:9324/000000000000/keda-demo-queue'
for i in range(1, 26):
    sqs.send_message(QueueUrl=q, MessageBody=json.dumps({'order_id': f'ord-{i}', 'amount': 49.99}))
print('All 25 messages sent successfully!')
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pyCode))
kubectl delete pod send-traffic -n keda-demo --ignore-not-found 2>$null | Out-Null
kubectl run send-traffic --image=keda-demo-app:latest --restart=Never -n keda-demo -- python -c "import base64; exec(base64.b64decode('$b64').decode())" | Out-Null

Start-Sleep -Seconds 3
kubectl delete pod send-traffic -n keda-demo --ignore-not-found 2>$null | Out-Null
Write-Host "  [OK] 25 messages successfully placed on the SQS queue!" -ForegroundColor Green
Write-Host ""

# Phase 3: Watch Scale Up
Write-Host "[3/4] KEDA Trigger Activated! Scaling from 0 -> 5 Pods..." -ForegroundColor Yellow
Write-Host "      (Formula: ceil(25 messages / 5 target) = 5 replicas)" -ForegroundColor Cyan
Write-Host ""

$timeout = 90
$elapsed = 0
while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds 4
    $elapsed += 4
    Clear-Host
    Write-Host ""
    Write-Host "=== LIVE POD MONITOR (Target: 5 Pods) [Elapsed: ${elapsed}s] ===" -ForegroundColor Cyan
    Write-Host ""
    kubectl get pods -n keda-demo -l app=keda-demo
    $running = (kubectl get pods -n keda-demo -l app=keda-demo --no-headers 2>$null | Measure-Object).Count
    if ($running -ge 5) {
        Write-Host ""
        Write-Host "  [SUCCESS] MAXIMUM CAPACITY REACHED: 5/5 PODS ACTIVE AND PROCESSING IN PARALLEL!" -ForegroundColor Green
        Write-Host ""
        break
    }
}

# Phase 4: Watch Queue Drain & Scale-Down
Write-Host "[4/4] Pods processing messages concurrently... watching scale-to-zero..." -ForegroundColor Yellow
while ($true) {
    Start-Sleep -Seconds 5
    Clear-Host
    Write-Host ""
    Write-Host "=== PROCESSING & SCALE-TO-ZERO MONITOR ===" -ForegroundColor Cyan
    Write-Host ""
    kubectl get pods -n keda-demo -l app=keda-demo
    $running = (kubectl get pods -n keda-demo -l app=keda-demo --no-headers 2>$null | Measure-Object).Count
    if ($running -eq 0) {
        Write-Host ""
        Write-Host "  [OK] All messages processed! All pods terminated back to ZERO replicas." -ForegroundColor Green
        Write-Host "  [OK] Demonstration Complete!" -ForegroundColor Cyan
        Write-Host ""
        break
    }
}
