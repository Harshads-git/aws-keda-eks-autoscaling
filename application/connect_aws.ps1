# =============================================================================
# connect_aws.ps1 — Connect SmartScale AI Dashboard directly to AWS Cloud SQS
# =============================================================================
param(
    [string]$AccessKey = $env:AWS_ACCESS_KEY_ID,
    [string]$SecretKey = $env:AWS_SECRET_ACCESS_KEY,
    [string]$Region    = "us-east-1",
    [string]$AccountId = ""
)

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   SmartScale AI: AWS Cloud Live Connection Setup" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Stop any old process holding port 8092
$oldProc = Get-NetTCPConnection -LocalPort 8092 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
if ($oldProc) {
    Write-Host "Stopping previous dashboard process (PID: $oldProc)..." -ForegroundColor Yellow
    Stop-Process -Id $oldProc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# Prompt if not set
if (-not $AccessKey -or $AccessKey -eq "test") {
    $AccessKey = Read-Host "Enter your AWS Access Key ID (starts with AKIA)"
}
if (-not $SecretKey -or $SecretKey -eq "test") {
    $SecretKey = Read-Host "Enter your AWS Secret Access Key"
}
if (-not $AccountId) {
    $AccountId = Read-Host "Enter your 12-digit AWS Account ID (from AWS console top-right)"
}

$AccessKey = $AccessKey.Trim()
$SecretKey = $SecretKey.Trim()
$AccountId = $AccountId.Trim()

# Export environment variables
$env:AWS_ACCESS_KEY_ID     = $AccessKey
$env:AWS_SECRET_ACCESS_KEY = $SecretKey
$env:AWS_DEFAULT_REGION    = $Region
$env:SQS_ENDPOINT_URL      = "https://sqs.$Region.amazonaws.com"
$env:PRIORITY_QUEUE_URL    = "https://sqs.$Region.amazonaws.com/$AccountId/priority-orders"
$env:BATCH_QUEUE_URL       = "https://sqs.$Region.amazonaws.com/$AccountId/batch-orders"
$env:DLQ_URL               = "https://sqs.$Region.amazonaws.com/$AccountId/dead-letter"

# Also write to local .env file so it persists
$envContent = @"
AWS_ACCESS_KEY_ID=$AccessKey
AWS_SECRET_ACCESS_KEY=$SecretKey
AWS_DEFAULT_REGION=$Region
SQS_ENDPOINT_URL=https://sqs.$Region.amazonaws.com
PRIORITY_QUEUE_URL=https://sqs.$Region.amazonaws.com/$AccountId/priority-orders
BATCH_QUEUE_URL=https://sqs.$Region.amazonaws.com/$AccountId/batch-orders
DLQ_URL=https://sqs.$Region.amazonaws.com/$AccountId/dead-letter
"@
Set-Content -Path (Join-Path $PSScriptRoot ".env") -Value $envContent -Force

Write-Host ""
Write-Host "Testing AWS SQS Connection to $Region..." -ForegroundColor Yellow
$testCode = @"
import os, boto3
from botocore.config import Config
c = boto3.client('sqs', region_name='$Region', aws_access_key_id='$AccessKey', aws_secret_access_key='$SecretKey', config=Config(connect_timeout=3, retries={'max_attempts':1}))
r = c.get_queue_attributes(QueueUrl='$env:PRIORITY_QUEUE_URL', AttributeNames=['ApproximateNumberOfMessages'])
print('SUCCESS: Connected! Queue Depth =', r['Attributes']['ApproximateNumberOfMessages'])
"@

try {
    $result = python -c $testCode 2>&1
    if ($result -match "SUCCESS") {
        Write-Host "  [OK] $result" -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] AWS returned: $result" -ForegroundColor Red
        Write-Host "  Please double check that priority-orders queue was created in $Region!" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [WARNING] Could not verify queue: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Starting SmartScale AI Dashboard in AWS Cloud Mode..." -ForegroundColor Green
Write-Host "Opening at http://localhost:8092" -ForegroundColor Cyan
Write-Host ""

Set-Location $PSScriptRoot
python -m uvicorn dashboard:app --host 0.0.0.0 --port 8092
