# Testing Guide: Unit, Integration, and End-to-End Tests

This guide explains the three-tier testing strategy for the KEDA demo,
when to run each tier, and how to interpret results.

---

## 1. Testing Pyramid

```
                    ╔══════════════════╗
                    ║   E2E Tests      ║  ← Slowest (10-15 min), Real AWS + K8s
                    ║  run-e2e-test.sh ║    Most confidence, highest cost
                    ╚══════════════════╝
               ╔════════════════════════════╗
               ║  Integration Tests         ║  ← Medium (1-2 min), Real SQS only
               ║  integration_test.py       ║    Catches IAM/network issues
               ╚════════════════════════════╝
          ╔══════════════════════════════════════╗
          ║  Unit Tests (moto mock)               ║  ← Fastest (<5s), No AWS needed
          ║  test_app.py                          ║    Always runs in CI
          ╚══════════════════════════════════════╝
```

Each tier catches different failure modes — all three are necessary.

---

## 2. Unit Tests — `application/test_app.py`

### When to Run
- **Always** — in CI on every PR, and locally before committing.

### Command
```bash
cd application
python -m pytest test_app.py -v --cov=app --cov-fail-under=80
```

### What It Tests
- `app.py` business logic: message parsing, error handling, retry loops
- SQS interactions mocked with `moto` — zero real AWS calls
- Coverage threshold: **80%** minimum (CI fails below this)

### What It Misses
- IAM permission errors (IRSA trust policy misconfiguration)
- Network routing issues (Security Groups, VPC CNI)
- Real SQS message lifecycle (visibility timeout, DLQ behaviour)

### Expected Output
```
collected 18 items

test_app.py::TestSQSConsumer::test_process_message_success PASSED
test_app.py::TestSQSConsumer::test_empty_queue_returns_none PASSED
...
---------- coverage: app.py -----------
TOTAL    152    22    86%
18 passed in 1.23s
```

---

## 3. Integration Tests — `application/integration_test.py`

### When to Run
- After `terraform apply` creates real SQS queues
- Before deploying to EKS (verify IAM + network works)
- When debugging SQS access issues

### Command
```bash
# Get queue URL from Terraform:
export SQS_QUEUE_URL=$(cd terraform && terraform output -raw sqs_queue_url)

# Run integration tests:
INTEGRATION_TESTS=true python -m pytest application/integration_test.py -v --timeout=60
```

### What It Tests

| Test Class | What It Validates |
|---|---|
| `TestSQSConnectivity` | Queue accessible, IRSA credentials work, ARN format correct |
| `TestMessageSendReceive` | Full send→receive→delete lifecycle |
| `TestQueueDepth` | `ApproximateNumberOfMessages` accuracy (the metric KEDA reads) |
| `TestMessageFormat` | JSON roundtrip (producer/consumer contract) |

### Skip Guard
All integration tests are **skipped by default**:
```python
pytestmark = pytest.mark.skipif(
    not INTEGRATION_TESTS_ENABLED,
    reason="Set INTEGRATION_TESTS=true to run against real AWS."
)
```
This prevents `pytest` in CI from accidentally calling real AWS APIs.

### Expected Output
```
collected 7 items

integration_test.py::TestSQSConnectivity::test_queue_is_accessible PASSED
integration_test.py::TestMessageSendReceive::test_send_single_message PASSED
...
7 passed in 8.45s
```

### Common Failures

```
AccessDenied: SQS:GetQueueAttributes
└── Fix: Check IRSA annotation on ServiceAccount
    kubectl get sa keda-demo -n keda-demo -o yaml | grep role-arn

AWS.SimpleQueueService.NonExistentQueue
└── Fix: Run terraform apply (queue not created yet)
    cd terraform && terraform apply

Connection timeout
└── Fix: Check NAT Gateway is running (pods in private subnets need NAT for SQS API)
    aws ec2 describe-nat-gateways --filter Name=state,Values=available
```

---

## 4. End-to-End Tests — `scripts/run-e2e-test.sh`

### When to Run
- After full stack deployment (Terraform + KEDA + manifests)
- To validate autoscaling works before declaring the project complete
- To reproduce a production incident in a controlled way

### Command
```bash
bash scripts/run-e2e-test.sh
# Or with more messages:
bash scripts/run-e2e-test.sh --messages 50
# Or skip scale-down wait (faster demo):
bash scripts/run-e2e-test.sh --no-wait
```

### What It Tests (6 Phases)

| Phase | Assertion |
|---|---|
| 1. Prerequisites | kubectl, KEDA CRDs, ScaledObject all present |
| 2. Baseline | Queue ≈ 0 messages, 0 pods (scale-to-zero working) |
| 3. Send messages | Queue depth increases to expected count |
| 4. Scale-up | KEDA creates ceil(N/5) pods within 180s |
| 5. Queue drain | All messages processed, queue empties within 300s |
| 6. Scale-to-zero | All pods terminate within 400s (300s cooldown + margin) |

### Timing Reference

```
Phase 1:  ~5s    (kubectl + API calls)
Phase 2:  ~5s    (queue depth check)
Phase 3:  ~10s   (send 25 messages)
Phase 4:  ~30-90s (KEDA polling interval + pod scheduling)
Phase 5:  ~60-180s (depends on message processing speed)
Phase 6:  ~300-350s (KEDA cooldownPeriod=300s is the floor)

Total E2E runtime: ~8-12 minutes
```

### Reading E2E Test Output

```
Phase 4: Observe KEDA Scale-Up (timeout: 180s)
────────────────────────────────────────
  ⏳ [ 45s] Pods in keda-demo: 5/5 expected
✔  PASS: KEDA scaled up to 5 pod(s) in 45s
```

Meaning: KEDA noticed the 25 messages in ~45 seconds and scheduled 5 pods.

---

## 5. Running All Tests Locally

```bash
# 1. Unit tests (always)
cd application && python -m pytest test_app.py -v

# 2. Integration tests (requires real SQS)
export SQS_QUEUE_URL=$(cd ../terraform && terraform output -raw sqs_queue_url)
INTEGRATION_TESTS=true python -m pytest integration_test.py -v

# 3. E2E tests (requires full stack)
cd .. && bash scripts/run-e2e-test.sh
```

---

## 6. Test Coverage Summary

| What We Test | How | AWS Cost |
|---|---|---|
| app.py logic | moto unit tests | Free (no real AWS) |
| SQS permissions | integration tests | ~\$0.001 per run |
| KEDA scaling | e2e test | ~\$0.10/run (EKS hours) |
| Terraform syntax | `terraform validate` (CI) | Free |
| Dockerfile build | Docker build in CI | Free |
| Conventional commits | PR title regex (CI) | Free |

---

## 7. Debugging Failed Tests

### Unit test fails: `ImportError`
```bash
cd application
pip install -r requirements.txt requirements-dev.txt
```

### Integration test: `AccessDenied`
```bash
# Check what credentials boto3 is using:
python3 -c "import boto3; print(boto3.session.Session().get_credentials().resolve_credentials())"

# Check IRSA annotation (if running inside EKS pod):
env | grep AWS_ROLE_ARN
```

### E2E test: Scale-up timeout (Phase 4)
```bash
# Check pod events:
kubectl describe pods -n keda-demo | grep -A 10 Events

# Check KEDA operator logs:
kubectl logs -n keda deploy/keda-operator --tail=50

# Check ScaledObject:
kubectl describe scaledobject keda-demo -n keda-demo
```

### E2E test: Queue not draining (Phase 5)
```bash
# Check consumer pod logs:
kubectl logs -n keda-demo -l app=keda-demo --tail=30

# Check for errors:
kubectl logs -n keda-demo -l app=keda-demo --tail=30 | grep ERROR
```
