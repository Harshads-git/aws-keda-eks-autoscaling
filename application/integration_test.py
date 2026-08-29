"""
application/integration_test.py — Real AWS Integration Tests
=============================================================
Unlike test_app.py (which uses moto SQS mock), these tests interact with
REAL AWS resources. They require:
  - AWS credentials configured (IRSA in EKS, or aws configure locally)
  - SQS_QUEUE_URL env var pointing to the real queue
  - The real SQS queue to already exist (created by Terraform)

Run locally:
  export SQS_QUEUE_URL=$(cd ../terraform && terraform output -raw sqs_queue_url)
  python -m pytest application/integration_test.py -v --timeout=60

Run in CI (skipped unless INTEGRATION_TESTS=true):
  INTEGRATION_TESTS=true pytest application/integration_test.py -v

Why real integration tests?
  moto is excellent for unit tests but cannot catch:
  - IAM permission errors (IRSA trust policy misconfiguration)
  - Network connectivity issues (SG blocks, VPC routing)
  - SQS quota limits or throttling
  - Real message lifecycle (visibility timeout, DLQ routing)
  - Concurrent consumer behaviour under real latency

GCP reference repo equivalent:
  tests/integration/test_pubsub.py (tests against real Pub/Sub)
  This file is the AWS SQS equivalent.
"""

import json
import os
import time
import uuid
import logging
import pytest
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

# ── Test Configuration ────────────────────────────────────────────────────────

QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

# Skip all integration tests unless explicitly enabled
# Prevents accidental real AWS usage in unit test runs
INTEGRATION_TESTS_ENABLED = os.environ.get("INTEGRATION_TESTS", "false").lower() == "true"

pytestmark = pytest.mark.skipif(
    not INTEGRATION_TESTS_ENABLED,
    reason="Integration tests skipped. Set INTEGRATION_TESTS=true to run against real AWS.",
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def sqs_client():
    """Real boto3 SQS client. Uses IRSA creds in EKS or aws configure locally."""
    return boto3.client("sqs", region_name=AWS_REGION)


@pytest.fixture(scope="module")
def queue_url(sqs_client):
    """Validate the SQS queue is accessible and return its URL."""
    if not QUEUE_URL:
        pytest.fail(
            "SQS_QUEUE_URL env var is required for integration tests.\n"
            "Get it: terraform output -raw sqs_queue_url"
        )

    # Verify queue exists and is accessible
    try:
        response = sqs_client.get_queue_attributes(
            QueueUrl=QUEUE_URL,
            AttributeNames=["QueueArn", "ApproximateNumberOfMessages"],
        )
        logger.info(f"Queue ARN: {response['Attributes']['QueueArn']}")
        logger.info(
            f"Messages in queue: {response['Attributes']['ApproximateNumberOfMessages']}"
        )
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AWS.SimpleQueueService.NonExistentQueue":
            pytest.fail(f"Queue not found: {QUEUE_URL}\nRun: terraform apply")
        elif code == "AccessDenied":
            pytest.fail(
                f"Access denied to {QUEUE_URL}\n"
                "Check IRSA role ARN annotation on ServiceAccount.\n"
                "Required permissions: sqs:GetQueueAttributes"
            )
        raise

    return QUEUE_URL


@pytest.fixture(autouse=True)
def cleanup_test_messages(sqs_client, queue_url):
    """
    Purge test messages after each test.
    Uses a unique test_id per test to identify messages belonging to this run.
    """
    yield  # Run the test first
    # Cleanup: purge ALL messages (integration tests own the queue)
    # In a shared queue, use message attributes to filter instead of purge.
    try:
        sqs_client.purge_queue(QueueUrl=queue_url)
        time.sleep(2)  # Purge takes up to 60s to complete
        logger.info("Queue purged after test")
    except ClientError as e:
        if e.response["Error"]["Code"] != "PurgeQueueInProgress":
            logger.warning(f"Failed to purge queue: {e}")


# ── Helpers ───────────────────────────────────────────────────────────────────

def send_test_message(sqs_client, queue_url, payload: dict) -> str:
    """Send a single test message and return the MessageId."""
    response = sqs_client.send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps(payload),
        MessageAttributes={
            "test_run_id": {
                "DataType": "String",
                "StringValue": payload.get("test_run_id", "unknown"),
            }
        },
    )
    return response["MessageId"]


def get_queue_depth(sqs_client, queue_url) -> int:
    """Return the approximate number of visible messages in the queue."""
    response = sqs_client.get_queue_attributes(
        QueueUrl=queue_url,
        AttributeNames=["ApproximateNumberOfMessages"],
    )
    return int(response["Attributes"]["ApproximateNumberOfMessages"])


def receive_messages(sqs_client, queue_url, max_count=10) -> list:
    """Receive up to max_count messages (long polling, 20s wait)."""
    response = sqs_client.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=min(max_count, 10),  # SQS max per call is 10
        WaitTimeSeconds=5,  # Long poll: wait up to 5s for messages
        MessageAttributeNames=["All"],
    )
    return response.get("Messages", [])


def delete_message(sqs_client, queue_url, receipt_handle: str):
    """Delete a message from the queue (simulate successful processing)."""
    sqs_client.delete_message(
        QueueUrl=queue_url,
        ReceiptHandle=receipt_handle,
    )


# ── Tests ─────────────────────────────────────────────────────────────────────

class TestSQSConnectivity:
    """Basic connectivity and auth tests — run first to fail fast."""

    def test_queue_is_accessible(self, sqs_client, queue_url):
        """Verify we can read queue attributes (tests GetQueueAttributes permission)."""
        response = sqs_client.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=["All"],
        )
        attrs = response["Attributes"]
        assert "QueueArn" in attrs, "QueueArn not in response"
        assert "VisibilityTimeout" in attrs
        logger.info(f"Queue ARN: {attrs['QueueArn']}")
        logger.info(f"Visibility timeout: {attrs['VisibilityTimeout']}s")

    def test_queue_arn_format(self, sqs_client, queue_url):
        """Validate the queue ARN follows expected format."""
        response = sqs_client.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=["QueueArn"],
        )
        arn = response["Attributes"]["QueueArn"]
        # Format: arn:aws:sqs:<region>:<account-id>:<queue-name>
        parts = arn.split(":")
        assert len(parts) == 6, f"Unexpected ARN format: {arn}"
        assert parts[0] == "arn"
        assert parts[1] == "aws"
        assert parts[2] == "sqs"
        logger.info(f"Queue ARN validated: {arn}")


class TestMessageSendReceive:
    """Message lifecycle tests — send, receive, delete."""

    def test_send_single_message(self, sqs_client, queue_url):
        """Verify we can send a message (tests SendMessage permission)."""
        test_id = str(uuid.uuid4())
        payload = {"event_type": "test", "test_id": test_id, "value": 42}

        message_id = send_test_message(sqs_client, queue_url, payload)
        assert message_id, "No MessageId returned from SQS"
        logger.info(f"Sent message: {message_id}")

    def test_receive_message(self, sqs_client, queue_url):
        """Verify we can receive a message we just sent."""
        test_id = str(uuid.uuid4())
        payload = {"event_type": "receive_test", "test_id": test_id}

        # Send message
        send_test_message(sqs_client, queue_url, payload)

        # Wait for message to be visible (SQS eventual consistency)
        time.sleep(2)

        # Receive message
        messages = receive_messages(sqs_client, queue_url)
        assert len(messages) >= 1, "No messages received from queue"

        # Find our specific message
        found = False
        for msg in messages:
            body = json.loads(msg["Body"])
            if body.get("test_id") == test_id:
                found = True
                assert body["event_type"] == "receive_test"
                logger.info(f"Received expected message: {msg['MessageId']}")
                break

        assert found, f"Our test message (test_id={test_id}) not found in received messages"

    def test_message_delete(self, sqs_client, queue_url):
        """Verify we can delete a message (simulates successful processing)."""
        test_id = str(uuid.uuid4())
        send_test_message(sqs_client, queue_url, {"test_id": test_id})
        time.sleep(2)

        messages = receive_messages(sqs_client, queue_url)
        assert messages, "No messages to delete"

        # Delete the first message
        receipt = messages[0]["ReceiptHandle"]
        delete_message(sqs_client, queue_url, receipt)
        logger.info("Message deleted successfully")


class TestQueueDepth:
    """Queue depth metric tests — these values drive KEDA scaling decisions."""

    def test_queue_depth_increases_on_send(self, sqs_client, queue_url):
        """
        Verify ApproximateNumberOfMessages increases after sending.
        This is the metric KEDA reads via GetQueueAttributes.
        """
        initial_depth = get_queue_depth(sqs_client, queue_url)
        messages_to_send = 5

        for i in range(messages_to_send):
            send_test_message(sqs_client, queue_url, {"index": i, "batch": "depth_test"})

        # SQS metrics update with slight delay
        time.sleep(3)

        new_depth = get_queue_depth(sqs_client, queue_url)
        assert new_depth >= initial_depth + messages_to_send, (
            f"Queue depth should have increased by {messages_to_send}. "
            f"Before: {initial_depth}, After: {new_depth}"
        )
        logger.info(f"Queue depth: {initial_depth} → {new_depth}")

    def test_keda_scaling_threshold(self, sqs_client, queue_url):
        """
        Simulate the message volume that should trigger KEDA to scale.
        KEDA ScaledObject: targetQueueLength=5, maxReplicaCount=5
        Expected replicas = ceil(queueDepth / targetQueueLength)
        """
        target_queue_length = 5  # from manifests/keda-scaled-object.yaml
        messages_for_max_scale = target_queue_length * 5  # = 25 messages → 5 replicas

        for i in range(messages_for_max_scale):
            send_test_message(sqs_client, queue_url, {
                "index": i,
                "batch": "scale_trigger_test",
                "test_run_id": str(uuid.uuid4()),
            })

        time.sleep(3)
        depth = get_queue_depth(sqs_client, queue_url)

        # KEDA formula: replicas = ceil(depth / targetQueueLength)
        expected_replicas = -(-depth // target_queue_length)  # ceiling division
        logger.info(
            f"Queue depth: {depth}, targetQueueLength: {target_queue_length}, "
            f"Expected KEDA replicas: {expected_replicas}"
        )

        assert depth >= messages_for_max_scale, (
            f"Expected at least {messages_for_max_scale} messages in queue, got {depth}"
        )
        assert expected_replicas >= 5, (
            f"Expected KEDA to scale to at least 5 replicas, formula gives {expected_replicas}"
        )


class TestMessageFormat:
    """Validate message format contract between producer and consumer."""

    def test_json_message_roundtrip(self, sqs_client, queue_url):
        """Messages must be valid JSON (app.py expects json.loads(body))."""
        test_payload = {
            "event_type": "order_placed",
            "order_id": str(uuid.uuid4()),
            "amount": 99.99,
            "items": ["item-1", "item-2"],
            "metadata": {"source": "integration_test"},
        }
        send_test_message(sqs_client, queue_url, test_payload)
        time.sleep(2)

        messages = receive_messages(sqs_client, queue_url)
        assert messages, "No messages received"

        received_body = json.loads(messages[0]["Body"])
        assert received_body["event_type"] == test_payload["event_type"]
        assert received_body["order_id"] == test_payload["order_id"]
        assert received_body["amount"] == test_payload["amount"]
        logger.info("JSON roundtrip successful")
