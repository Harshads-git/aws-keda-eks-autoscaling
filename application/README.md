# Application: SQS Consumer

This directory contains the Python SQS consumer that KEDA scales based on
queue depth. It is the AWS port of the GCP Pub/Sub consumer from the
[reference repository](https://github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo).

---

## Files

| File | Purpose |
|---|---|
| `app.py` | SQS consumer — the application that runs in EKS pods |
| `requirements.txt` | Production dependencies (boto3, python-json-logger) |
| `requirements-dev.txt` | Dev/test dependencies (moto, pytest, ruff) |
| `test_app.py` | Unit tests using moto (no real AWS needed) |
| `Dockerfile` | Multi-stage Docker image definition |
| `.dockerignore` | Excludes dev files from Docker build context |

---

## GCP → AWS Translation

```python
# GCP original (reference repo)
from google.cloud import pubsub_v1

subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(PROJECT, SUBSCRIPTION)

def process_payload(message):
    print(f"Received {message.data}.")
    message.ack()                         # ← Pub/Sub ack

subscriber.subscribe(subscription_path, callback=process_payload)

# ─────────────────────────────────────────────────────────────

# AWS version (this file)
import boto3

sqs = boto3.client("sqs")
response = sqs.receive_message(QueueUrl=QUEUE_URL, WaitTimeSeconds=20)

def process_message(message):
    print(f"Received {message['Body']}.")
    sqs.delete_message(                   # ← SQS explicit delete
        QueueUrl=QUEUE_URL,
        ReceiptHandle=message["ReceiptHandle"]
    )
```

---

## Local Development Setup

### Prerequisites

- Python 3.11+
- pip

### 1. Create a virtual environment

```bash
cd application
python -m venv .venv

# Activate (Linux/Mac)
source .venv/bin/activate

# Activate (Windows PowerShell)
.venv\Scripts\Activate.ps1
```

### 2. Install dependencies

```bash
# Production dependencies only
pip install -r requirements.txt

# Development + test dependencies
pip install -r requirements-dev.txt
```

---

## Running Tests (No AWS Account Needed)

Tests use **moto** — a Python library that mocks all AWS API calls in-memory.
No real AWS credentials, SQS queue, or network access required.

```bash
# Run all tests
pytest test_app.py -v

# Run with coverage report
pytest test_app.py -v --cov=app --cov-report=term-missing

# Run a specific test class
pytest test_app.py::TestKEDAScalingBehavior -v

# Run a specific test
pytest test_app.py::TestProcessMessage::test_returns_true_on_success -v
```

### Expected output

```
========================= test session starts ==========================
test_app.py::TestLoadConfig::test_raises_when_queue_url_missing PASSED
test_app.py::TestLoadConfig::test_raises_when_queue_url_is_blank PASSED
test_app.py::TestLoadConfig::test_loads_queue_url_from_env       PASSED
test_app.py::TestLoadConfig::test_defaults_region_to_us_east_1   PASSED
test_app.py::TestLoadConfig::test_loads_custom_region            PASSED
test_app.py::TestLoadConfig::test_defaults_log_level_to_info     PASSED
...
test_app.py::TestKEDAScalingBehavior::test_full_keda_lifecycle   PASSED
========================= 20 passed in 1.23s ==========================
```

### Coverage report

```bash
pytest test_app.py --cov=app --cov-report=term-missing
```

```
Name     Stmts   Miss  Cover   Missing
--------------------------------------
app.py     148     12    92%   201-203, 220-225
```

---

## Running Locally Against Real AWS SQS

> ⚠️ Requires AWS CLI configured and SQS queue created (see `scripts/setup-sqs.sh`)

### 1. Set required environment variables

```bash
# Copy and edit .env in the project root
cp ../.env.example ../.env
# Edit ../.env with your actual values

# Or set inline:
export SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/123456789012/keda-demo-queue"
export AWS_REGION="us-east-1"
export LOG_LEVEL="DEBUG"
```

### 2. Run the consumer

```bash
python app.py
```

### 3. Send test messages in another terminal

```bash
# From the project root
bash scripts/generate-messages.sh --count 5
```

You should see the consumer log output:
```json
{"asctime": "2026-08-15T22:23:00", "name": "keda-demo", "levelname": "INFO",
 "message": "Received message: keda-demo-message-1 | batch=1 | ...",
 "message_id": "abc-123", "body": "keda-demo-message-1 | ..."}
```

---

## Building the Docker Image Locally

```bash
# From the project root (not the application/ directory)
docker build -t keda-demo-app:local ./application

# Run the container locally
docker run --rm \
  -e SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/123456789012/keda-demo-queue" \
  -e AWS_REGION="us-east-1" \
  -e AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)" \
  -e AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)" \
  keda-demo-app:local
```

> **Note:** When running in EKS, IRSA provides credentials automatically via
> the projected ServiceAccount token. The `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
> env vars are only needed for local Docker testing.

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `SQS_QUEUE_URL` | ✅ Yes | — | Full SQS queue URL |
| `AWS_REGION` | No | `us-east-1` | AWS region |
| `LOG_LEVEL` | No | `INFO` | Logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |
| `SQS_WAIT_TIME_SECONDS` | No | `20` | Long polling wait time (0–20s) |
| `SQS_MAX_MESSAGES` | No | `1` | Messages per receive call (1–10) |
| `SQS_VISIBILITY_TIMEOUT` | No | `30` | Override queue visibility timeout |
| `HEALTH_FILE` | No | `/tmp/healthy` | Path for Kubernetes HEALTHCHECK file |
| `SHUTDOWN_TIMEOUT_SECONDS` | No | `30` | Max time to finish message before exit |

---

## KEDA Scaling Behaviour

```
SQS Queue Depth    Desired Replicas   Formula: ceil(depth / 5)
─────────────────  ─────────────────  ──────────────────────────
0 messages         0 pods             ceil(0/5)  = 0 (scale to zero ✨)
1–5 messages       1 pod              ceil(5/5)  = 1
6–10 messages      2 pods             ceil(10/5) = 2
11–15 messages     3 pods             ceil(15/5) = 3
16–20 messages     4 pods             ceil(20/5) = 4
21+ messages       5 pods (max)       capped at maxReplicaCount
```

When a pod is terminated by KEDA (scale-down), Kubernetes sends `SIGTERM`.
The consumer's signal handler finishes the current message, removes the
health file, and exits cleanly — ensuring no message is lost during scale-down.
