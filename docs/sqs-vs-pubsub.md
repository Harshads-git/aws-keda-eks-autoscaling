# SQS vs Cloud Pub/Sub: A Deep Dive for KEDA Engineers

This document explains the architectural differences between Amazon SQS and
Google Cloud Pub/Sub, specifically through the lens of how KEDA uses each
service as an autoscaling trigger. Understanding these differences is essential
for understanding why the AWS and GCP implementations behave differently.

---

## 1. The Core Difference: Pull vs. Push

The most fundamental difference is the **delivery model**.

```
Google Cloud Pub/Sub (Push + Pull)        Amazon SQS (Pull only)
─────────────────────────────────         ──────────────────────
Publisher                                 Producer
    │                                         │
    ▼                                         ▼
  Topic ──── Subscription (Push) ──▶ HTTP endpoint (your server)
    │
    └─── Subscription (Pull) ──▶ Consumer calls pull() API
                                             Consumer calls ReceiveMessage()
```

**Pub/Sub Push:** The infrastructure delivers messages TO your application's
HTTP endpoint. You don't need to poll.

**SQS Pull:** Your application ASKS for messages via the `ReceiveMessage` API.
The infrastructure holds messages until asked. This is what our `app.py` does.

**Why this matters for KEDA:**
- Both expose a "messages waiting" metric that KEDA reads
- SQS: `ApproximateNumberOfMessages` (via `GetQueueAttributes`)
- Pub/Sub: `num_undelivered_messages` (via Cloud Monitoring API)
- The pull model means messages stay in the queue until explicitly deleted,
  making the depth metric directly meaningful for scaling

---

## 2. Message Lifecycle Comparison

### Cloud Pub/Sub Lifecycle

```
1. Publisher sends message to Topic
2. Pub/Sub delivers to Subscription
3. Consumer receives message (pulled or pushed)
4. Consumer calls message.ack()          ← message permanently removed
   OR
   Consumer calls message.nack()         ← message redelivered
   OR
   Ack deadline expires                  ← message redelivered
```

### Amazon SQS Lifecycle

```
1. Producer sends message to Queue
2. Consumer calls ReceiveMessage()
   └── Message becomes INVISIBLE for VisibilityTimeout seconds
3a. Consumer processes successfully → calls DeleteMessage()  ← permanently removed
3b. Consumer fails → VisibilityTimeout expires → message REAPPEARS
3c. Consumer fails N times (maxReceiveCount) → message moves to DLQ
```

**Key insight:** In SQS, a message is NOT deleted until the consumer explicitly
calls `DeleteMessage`. If your pod crashes mid-processing, the message
automatically reappears after the VisibilityTimeout expires and can be
reprocessed by another pod.

```python
# GCP Pub/Sub app.py (reference repo)
def process_payload(message):
    print(f"Received {message.data}.")
    message.ack()            # One call: process AND acknowledge

# AWS SQS app.py (this repo)
def process_message(message):
    print(f"Received {message['Body']}.")
    # ... do the work ...
    sqs.delete_message(      # Explicit delete AFTER successful processing
        QueueUrl=QUEUE_URL,
        ReceiptHandle=message['ReceiptHandle']
    )
```

---

## 3. Visibility Timeout: The SQS Safety Net

The Visibility Timeout is a concept that has no direct equivalent in Pub/Sub.

```
Time ─────────────────────────────────────────────────────────────────▶

Message arrives in queue:  [VISIBLE - any consumer can receive it]
                                │
Consumer calls ReceiveMessage():│
                                ▼
Message is INVISIBLE:          [░░░░░░░░░░░░░░░░░░] 30 seconds
                                                   │
                        If DeleteMessage() called: ▼
                                               [DELETED] ✔ Success

                        If NOT deleted by 30s:     │
                                                   ▼
                               [VISIBLE again - ready for reprocessing]
```

**Configuration in this project:** `SQS_VISIBILITY_TIMEOUT=30`

**The interaction with KEDA:**
- KEDA reads `ApproximateNumberOfMessages` (visible messages)
- It does NOT count `ApproximateNumberOfMessagesNotVisible` (in-flight)
- This means: if 5 pods are each processing 1 message, KEDA sees 0 new
  messages and won't scale up further (messages are hidden)
- This is actually correct behavior — the work is being done!

---

## 4. Long Polling: The SQS Cost Saver

**Short polling (default, inefficient):**
```
Consumer ──▶ ReceiveMessage() ──▶ SQS
             "Any messages?"
SQS ──▶ "Nope, empty" ──▶ Consumer   (API call cost, even for empty response)
Consumer waits 1 second
Consumer ──▶ ReceiveMessage() ──▶ SQS  (repeat 60x per minute)
```

**Long polling (configured in this project):**
```
Consumer ──▶ ReceiveMessage(WaitTimeSeconds=20) ──▶ SQS
             "Any messages? I'll wait up to 20s"
[20 seconds pass or message arrives...]
SQS ──▶ "Here's a message!" ──▶ Consumer   (one API call, got a message)
```

**`ReceiveMessageWaitTimeSeconds=20` in `setup-sqs.sh` saves:**
- Reduces API calls from ~3,600/hour to ~180/hour (20x reduction)
- Reduces SQS cost from ~$1.44/million to ~$0.072/million API calls
- Reduces CPU burn in the consumer (less spin-polling)

---

## 5. Dead Letter Queue (DLQ): SQS's Poison Message Handler

Pub/Sub has "dead letter topics" (similar concept). SQS has DLQs.

```
Normal flow:
  Main Queue ──▶ Consumer ──▶ Process ──▶ DeleteMessage ──▶ Done ✔

Failure flow (maxReceiveCount=3):
  Main Queue ──▶ Consumer ──▶ CRASH (attempt 1)
  Main Queue ──▶ Consumer ──▶ CRASH (attempt 2)
  Main Queue ──▶ Consumer ──▶ CRASH (attempt 3)
                                        │
                                        ▼
                              Dead Letter Queue  ← message lands here
                              (14-day retention, inspect & fix)
```

**KEDA + DLQ:**
- KEDA only scales on the main queue depth
- DLQ depth should trigger a **CloudWatch Alarm** (Day 24), not pod scaling
- High DLQ depth = bug in message processing, not a load problem

---

## 6. KEDA Scaler Comparison: Pub/Sub vs SQS

### GCP Pub/Sub ScaledObject (reference repo)

```yaml
# manifests/keda-resources.yaml (GCP reference)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  triggers:
    - type: gcp-pub-sub
      authenticationRef:
        name: keda-demo-trigger-auth-gcp-credentials
      metadata:
        subscriptionName: keda-demo-topic-subscription
        subscriptionSize: "5"    # scale 1 replica per 5 undelivered messages
```

**Metric used:** `num_undelivered_messages` from Cloud Monitoring

### AWS SQS ScaledObject (this project)

```yaml
# manifests/keda-scaled-object.yaml (AWS — Day 18)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: keda-trigger-auth-aws
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456789/keda-demo-queue
        queueLength: "5"        # scale 1 replica per 5 visible messages
        awsRegion: us-east-1
        scaleOnInFlight: "false" # don't count in-flight messages
```

**Metric used:** `ApproximateNumberOfMessages` from SQS GetQueueAttributes

### Key difference in metric:

| Aspect | GCP Pub/Sub | AWS SQS |
|---|---|---|
| **Metric name** | `num_undelivered_messages` | `ApproximateNumberOfMessages` |
| **In-flight counting** | Counts unacked messages | Excludes in-flight by default |
| **Metric source** | Cloud Monitoring API | SQS GetQueueAttributes API |
| **KEDA auth type** | `podIdentity.provider: gcp` | `podIdentity.provider: aws` |
| **Credential mechanism** | Workload Identity | IRSA (OIDC + STS) |

---

## 7. Pricing Comparison

| Metric | Cloud Pub/Sub | Amazon SQS |
|---|---|---|
| **Free tier** | First 10 GB/month free | First 1M requests/month free |
| **Message size limit** | 10 MB | 256 KB |
| **Ordering** | Ordered subscriptions available | FIFO queue (separate type) |
| **At-least-once delivery** | ✅ Yes | ✅ Yes |
| **Exactly-once delivery** | ❌ No | ✅ FIFO + deduplication |
| **KEDA maturity** | Good | Excellent (native, well-tested) |

For this project's scale (testing only):
- SQS cost: effectively **$0** (well within free tier)
- Pub/Sub cost: effectively **$0** (well within free tier)

---

## 8. Summary: Why SQS is the Right Choice Here

1. **KEDA's SQS scaler is the most mature** of all KEDA scalers — battle-tested
   in thousands of production deployments
2. **Pull model is simpler to reason about** for scale-to-zero: the queue depth
   is a perfect proxy for "work that needs to be done"
3. **No push endpoint needed** — the consumer runs as a K8s Deployment that
   continuously polls SQS, which is the natural Kubernetes pattern
4. **Visibility timeout** provides built-in at-least-once processing guarantees
   without needing application-level retry logic
5. **DLQ integration** gives immediate poison-message isolation with zero
   additional code in the consumer

---

## References

- [KEDA AWS SQS Scaler docs](https://keda.sh/docs/scalers/aws-sqs/)
- [KEDA GCP Pub/Sub Scaler docs](https://keda.sh/docs/scalers/gcp-pub-sub/)
- [SQS Visibility Timeout guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html)
- [SQS Long Polling guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html)
- [SQS Dead Letter Queues](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html)
