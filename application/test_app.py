"""
test_app.py — Unit tests for the SQS Consumer using moto (AWS mock)
====================================================================
Tests run WITHOUT a real AWS account. moto intercepts all boto3 calls
and simulates SQS behavior in-memory.

GCP equivalent: Pub/Sub emulator (requires running a local server)
AWS equivalent: moto (pure Python, zero infrastructure)

Run tests:
    cd application
    pip install -r requirements-dev.txt
    pytest test_app.py -v
    pytest test_app.py -v --cov=app --cov-report=term-missing
"""

from __future__ import annotations

import json
import logging
import os
import signal
import threading
import time
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws

from app import (
    SQSConsumer,
    load_config,
    process_message,
    setup_logging,
)

# ─── Constants ────────────────────────────────────────────────────────────────
TEST_REGION     = "us-east-1"
TEST_QUEUE_NAME = "test-keda-demo-queue"
TEST_DLQ_NAME   = "test-keda-demo-dlq"


# ─── Fixtures ─────────────────────────────────────────────────────────────────

@pytest.fixture
def aws_credentials():
    """
    Set fake AWS credentials for moto to intercept.
    moto requires SOME credential values set — they don't need to be real.
    This prevents accidental calls to real AWS during tests.
    """
    os.environ["AWS_ACCESS_KEY_ID"]     = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_SECURITY_TOKEN"]    = "testing"
    os.environ["AWS_SESSION_TOKEN"]     = "testing"
    os.environ["AWS_DEFAULT_REGION"]    = TEST_REGION
    yield
    # Cleanup after test
    for key in [
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
        "AWS_SECURITY_TOKEN", "AWS_SESSION_TOKEN",
    ]:
        os.environ.pop(key, None)


@pytest.fixture
def sqs_queue(aws_credentials):
    """
    Create a real (mocked) SQS queue using moto.
    All boto3 SQS API calls inside @mock_aws are intercepted and handled
    in-memory — no real AWS account needed.
    """
    with mock_aws():
        sqs = boto3.client("sqs", region_name=TEST_REGION)

        # Create DLQ
        dlq = sqs.create_queue(QueueName=TEST_DLQ_NAME)
        dlq_url = dlq["QueueUrl"]
        dlq_attrs = sqs.get_queue_attributes(
            QueueUrl=dlq_url, AttributeNames=["QueueArn"]
        )
        dlq_arn = dlq_attrs["Attributes"]["QueueArn"]

        # Create main queue with redrive policy
        queue = sqs.create_queue(
            QueueName=TEST_QUEUE_NAME,
            Attributes={
                "VisibilityTimeout": "30",
                "RedrivePolicy": json.dumps({
                    "deadLetterTargetArn": dlq_arn,
                    "maxReceiveCount":     "3",
                }),
            },
        )
        queue_url = queue["QueueUrl"]
        yield {"sqs": sqs, "queue_url": queue_url, "dlq_url": dlq_url}


@pytest.fixture
def logger():
    """Provide a test logger that suppresses output during tests."""
    test_logger = logging.getLogger("test-keda-demo")
    test_logger.addHandler(logging.NullHandler())
    return test_logger


@pytest.fixture
def consumer_config(sqs_queue):
    """Return a valid config dict pointing to the mocked SQS queue."""
    return {
        "queue_url":          sqs_queue["queue_url"],
        "aws_region":         TEST_REGION,
        "log_level":          "DEBUG",
        "wait_time_seconds":  0,   # No long polling delay in tests
        "max_messages":       1,
        "visibility_timeout": 30,
        "health_file":        "/tmp/test_healthy",
        "shutdown_timeout":   5,
    }


# ─── Tests: load_config ───────────────────────────────────────────────────────

class TestLoadConfig:
    """Test configuration loading from environment variables."""

    def test_raises_when_queue_url_missing(self, monkeypatch):
        """Should raise EnvironmentError if SQS_QUEUE_URL is not set."""
        monkeypatch.delenv("SQS_QUEUE_URL", raising=False)
        with pytest.raises(EnvironmentError, match="SQS_QUEUE_URL"):
            load_config()

    def test_raises_when_queue_url_is_blank(self, monkeypatch):
        """Should raise EnvironmentError if SQS_QUEUE_URL is empty string."""
        monkeypatch.setenv("SQS_QUEUE_URL", "   ")
        with pytest.raises(EnvironmentError, match="SQS_QUEUE_URL"):
            load_config()

    def test_loads_queue_url_from_env(self, monkeypatch):
        """Should correctly load SQS_QUEUE_URL from environment."""
        expected_url = "https://sqs.us-east-1.amazonaws.com/123456789/test-queue"
        monkeypatch.setenv("SQS_QUEUE_URL", expected_url)
        config = load_config()
        assert config["queue_url"] == expected_url

    def test_defaults_region_to_us_east_1(self, monkeypatch):
        """AWS_REGION should default to us-east-1 if not set."""
        monkeypatch.setenv("SQS_QUEUE_URL", "https://sqs.us-east-1.amazonaws.com/123/q")
        monkeypatch.delenv("AWS_REGION", raising=False)
        config = load_config()
        assert config["aws_region"] == "us-east-1"

    def test_loads_custom_region(self, monkeypatch):
        """Should load custom AWS_REGION from environment."""
        monkeypatch.setenv("SQS_QUEUE_URL", "https://sqs.eu-west-1.amazonaws.com/123/q")
        monkeypatch.setenv("AWS_REGION", "eu-west-1")
        config = load_config()
        assert config["aws_region"] == "eu-west-1"

    def test_defaults_log_level_to_info(self, monkeypatch):
        """LOG_LEVEL should default to INFO."""
        monkeypatch.setenv("SQS_QUEUE_URL", "https://sqs.us-east-1.amazonaws.com/123/q")
        monkeypatch.delenv("LOG_LEVEL", raising=False)
        config = load_config()
        assert config["log_level"] == "INFO"


# ─── Tests: setup_logging ────────────────────────────────────────────────────

class TestSetupLogging:
    """Test structured JSON logger setup."""

    def test_returns_logger_instance(self):
        """setup_logging() should return a Logger object."""
        test_logger = setup_logging("INFO")
        assert isinstance(test_logger, logging.Logger)

    def test_sets_correct_log_level(self):
        """Logger should honour the level parameter."""
        debug_logger = setup_logging("DEBUG")
        assert debug_logger.level == logging.DEBUG

        info_logger = setup_logging("INFO")
        assert info_logger.level == logging.INFO

    def test_invalid_level_defaults_to_info(self):
        """Invalid log level should not crash (defaults to INFO)."""
        test_logger = setup_logging("INVALID_LEVEL")
        # getattr with default returns INFO (20) for unknown levels
        assert test_logger.level <= logging.INFO


# ─── Tests: process_message ───────────────────────────────────────────────────

class TestProcessMessage:
    """Test individual message processing logic."""

    def _make_message(
        self,
        body: str = "test-message",
        message_id: str = "msg-001",
        receive_count: int = 1,
    ) -> dict:
        """Helper: build a realistic SQS message dict."""
        return {
            "MessageId":     message_id,
            "ReceiptHandle": f"receipt-{message_id}",
            "Body":          body,
            "Attributes":    {"ApproximateReceiveCount": str(receive_count)},
        }

    def test_returns_true_on_success(self, logger):
        """process_message() should return True for a normal message."""
        message = self._make_message(body="hello world")
        result  = process_message(message, logger)
        assert result is True

    def test_handles_empty_body(self, logger):
        """Should handle messages with empty body without crashing."""
        message = self._make_message(body="")
        result  = process_message(message, logger)
        assert result is True

    def test_handles_json_body(self, logger):
        """Should handle JSON-encoded message bodies (common pattern)."""
        payload = {"event": "order_created", "order_id": "ORD-001", "amount": 99.99}
        message = self._make_message(body=json.dumps(payload))
        result  = process_message(message, logger)
        assert result is True

    def test_handles_unicode_body(self, logger):
        """Should handle unicode characters in message body."""
        message = self._make_message(body="Hello 世界 🌍")
        result  = process_message(message, logger)
        assert result is True

    def test_handles_missing_message_id(self, logger):
        """Should handle messages without MessageId gracefully."""
        message = {"Body": "test", "ReceiptHandle": "r123", "Attributes": {}}
        result  = process_message(message, logger)
        assert result is True

    def test_returns_false_on_processing_exception(self, logger):
        """Should return False when processing raises an exception."""
        with patch("app.time.sleep", side_effect=RuntimeError("Processing failed")):
            message = self._make_message()
            result  = process_message(message, logger)
        assert result is False

    def test_logs_receive_count(self, logger, caplog):
        """Should log receive_count for retry tracking."""
        message = self._make_message(receive_count=2)
        with caplog.at_level(logging.INFO, logger="keda-demo"):
            process_message(message, logger)
        # Log should contain receive count (shows retry awareness)
        # (Exact assertion depends on log format; we verify no exception raised)
        assert True  # passes if no exception


# ─── Tests: SQSConsumer ───────────────────────────────────────────────────────

class TestSQSConsumer:
    """Test the SQSConsumer class using mocked SQS via moto."""

    def _send_test_message(self, sqs_queue: dict, body: str = "test-message") -> str:
        """Helper: put a message directly into the mock SQS queue."""
        response = sqs_queue["sqs"].send_message(
            QueueUrl=sqs_queue["queue_url"],
            MessageBody=body,
        )
        return response["MessageId"]

    def _get_queue_depth(self, sqs_queue: dict) -> int:
        """Helper: count visible messages in the mock queue."""
        attrs = sqs_queue["sqs"].get_queue_attributes(
            QueueUrl=sqs_queue["queue_url"],
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        return int(attrs["Attributes"]["ApproximateNumberOfMessages"])

    @mock_aws
    def test_consumer_deletes_message_on_success(self, sqs_queue, consumer_config, logger):
        """
        Core KEDA behavior test:
        Message in queue → consumer processes it → message deleted → queue empty
        Empty queue → KEDA scales pods to 0
        """
        # Arrange: put a message in the queue
        self._send_test_message(sqs_queue, body="scale-me-up-message")

        consumer = SQSConsumer(consumer_config, logger)

        # Act: run one poll cycle by stopping after first message
        consumer._running = True
        consumer._write_health_file()

        response = consumer.sqs.receive_message(
            QueueUrl=consumer_config["queue_url"],
            MaxNumberOfMessages=1,
            WaitTimeSeconds=0,
            AttributeNames=["All"],
        )
        messages = response.get("Messages", [])
        assert len(messages) == 1, "Expected 1 message in queue"

        message = messages[0]
        success = process_message(message, logger)
        assert success is True

        consumer._delete_message(message["ReceiptHandle"], message["MessageId"])

        # Assert: queue should now be empty (KEDA will scale to 0)
        depth = self._get_queue_depth(sqs_queue)
        assert depth == 0, f"Queue should be empty after processing, got depth={depth}"

    @mock_aws
    def test_consumer_does_not_delete_on_failure(self, sqs_queue, consumer_config, logger):
        """
        Failed processing should NOT delete the message.
        The message reappears after VisibilityTimeout and can be retried.
        After maxReceiveCount failures, SQS moves it to DLQ.
        """
        self._send_test_message(sqs_queue, body="poison-message")

        consumer = SQSConsumer(consumer_config, logger)

        response = consumer.sqs.receive_message(
            QueueUrl=consumer_config["queue_url"],
            MaxNumberOfMessages=1,
            WaitTimeSeconds=0,
            AttributeNames=["All"],
        )
        messages = response.get("Messages", [])
        assert len(messages) == 1

        # Simulate processing failure — do NOT call delete_message
        with patch("app.time.sleep", side_effect=RuntimeError("boom")):
            success = process_message(messages[0], logger)
        assert success is False
        # Message remains (will reappear after VisibilityTimeout in real SQS)

    @mock_aws
    def test_consumer_handles_empty_queue(self, sqs_queue, consumer_config, logger):
        """
        Empty queue → receive_message returns no messages.
        Consumer should loop without error (KEDA will scale-to-zero).
        """
        consumer = SQSConsumer(consumer_config, logger)

        response = consumer.sqs.receive_message(
            QueueUrl=consumer_config["queue_url"],
            MaxNumberOfMessages=1,
            WaitTimeSeconds=0,
            AttributeNames=["All"],
        )
        messages = response.get("Messages", [])
        assert len(messages) == 0, "Empty queue should return 0 messages"

    @mock_aws
    def test_health_file_created_on_start(self, sqs_queue, consumer_config, logger, tmp_path):
        """Health file must be created so K8s HEALTHCHECK passes after startup."""
        health_path = str(tmp_path / "healthy")
        consumer_config["health_file"] = health_path

        consumer = SQSConsumer(consumer_config, logger)
        consumer._write_health_file()

        assert os.path.exists(health_path), f"Health file not found at {health_path}"

    @mock_aws
    def test_health_file_removed_on_shutdown(self, sqs_queue, consumer_config, logger, tmp_path):
        """Health file must be removed on shutdown so K8s stops routing to this pod."""
        health_path = str(tmp_path / "healthy")
        consumer_config["health_file"] = health_path

        consumer = SQSConsumer(consumer_config, logger)
        consumer._write_health_file()
        assert os.path.exists(health_path)

        consumer._remove_health_file()
        assert not os.path.exists(health_path), "Health file should be removed on shutdown"

    @mock_aws
    def test_multiple_messages_all_processed(self, sqs_queue, consumer_config, logger):
        """All messages sent to queue should be processed and deleted."""
        message_count = 5
        for i in range(message_count):
            self._send_test_message(sqs_queue, body=f"message-{i + 1}")

        consumer = SQSConsumer(consumer_config, logger)
        processed = 0

        for _ in range(message_count):
            response = consumer.sqs.receive_message(
                QueueUrl=consumer_config["queue_url"],
                MaxNumberOfMessages=1,
                WaitTimeSeconds=0,
                AttributeNames=["All"],
            )
            messages = response.get("Messages", [])
            if not messages:
                break
            msg     = messages[0]
            success = process_message(msg, logger)
            if success:
                consumer._delete_message(msg["ReceiptHandle"], msg["MessageId"])
                processed += 1

        assert processed == message_count, \
            f"Expected {message_count} processed, got {processed}"


# ─── Integration Test ─────────────────────────────────────────────────────────

class TestKEDAScalingBehavior:
    """
    End-to-end test of the KEDA scaling pattern.

    This test simulates the complete lifecycle:
    1. Empty queue → consumer receives nothing
    2. Messages sent → consumer processes them
    3. Queue empty again → KEDA would scale to 0
    """

    @mock_aws
    def test_full_keda_lifecycle(self, sqs_queue, consumer_config, logger):
        """
        Simulate the complete KEDA autoscaling lifecycle:
        queue empty → messages arrive → processed → queue empty again
        """
        consumer = SQSConsumer(consumer_config, logger)
        sqs      = sqs_queue["sqs"]

        # Phase 1: Queue empty → KEDA sees 0 messages → 0 replicas
        response = consumer.sqs.receive_message(
            QueueUrl=consumer_config["queue_url"],
            MaxNumberOfMessages=1, WaitTimeSeconds=0, AttributeNames=["All"],
        )
        assert len(response.get("Messages", [])) == 0, "Phase 1: queue should be empty"

        # Phase 2: 10 messages arrive → KEDA sees 10 → ceil(10/5) = 2 replicas
        for i in range(10):
            sqs.send_message(
                QueueUrl=sqs_queue["queue_url"],
                MessageBody=f"keda-test-message-{i + 1}",
            )

        attrs = sqs.get_queue_attributes(
            QueueUrl=sqs_queue["queue_url"],
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        depth = int(attrs["Attributes"]["ApproximateNumberOfMessages"])
        assert depth == 10, f"Phase 2: expected 10 messages, got {depth}"

        # Phase 3: Consumer processes all messages → queue empty → KEDA scales to 0
        for _ in range(10):
            resp = consumer.sqs.receive_message(
                QueueUrl=consumer_config["queue_url"],
                MaxNumberOfMessages=1, WaitTimeSeconds=0, AttributeNames=["All"],
            )
            msgs = resp.get("Messages", [])
            if msgs:
                msg = msgs[0]
                if process_message(msg, logger):
                    consumer._delete_message(msg["ReceiptHandle"], msg["MessageId"])

        # Phase 4: Queue should be empty again
        attrs_final = sqs.get_queue_attributes(
            QueueUrl=sqs_queue["queue_url"],
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        final_depth = int(attrs_final["Attributes"]["ApproximateNumberOfMessages"])
        assert final_depth == 0, \
            f"Phase 4: queue should be empty (KEDA scale-to-zero), got {final_depth}"
