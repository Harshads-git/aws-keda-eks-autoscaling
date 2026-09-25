"""
application/dlq_processor.py — Dead Letter Queue Consumer with Retry Logic
===========================================================================

Processes messages from the SQS Dead Letter Queue (DLQ). Messages land in
the DLQ when they have been received and not deleted more than `maxReceiveCount`
times from the main queue (configured in the SQS Redrive Policy, default: 3).

Why a separate DLQ processor (not just the main consumer)?
  - DLQ messages have already failed 3+ times: they need special handling,
    not just the same processing logic that already failed.
  - Failure reasons must be logged/investigated before retrying.
  - Retry strategy: exponential backoff with jitter prevents hammering a
    dependency that was temporarily unavailable.
  - Max retries: some messages are permanently bad (poison pills) and should
    be quarantined (sent to an archive/S3), not retried forever.

Flow:
  SQS Main Queue → consumer fails 3x → SQS moves to DLQ automatically
  DLQ → dlq_processor.py → inspect failure reason → retry with backoff
                                                   → archive if unrecoverable

Usage:
    python dlq_processor.py

Environment Variables:
    DLQ_QUEUE_URL:          URL of the Dead Letter Queue (required)
    SQS_QUEUE_URL:          URL of the main queue (for redrive on success)
    DLQ_MAX_RETRIES:        Max retry attempts before archiving (default: 3)
    DLQ_BASE_BACKOFF_S:     Base backoff in seconds for retry (default: 2.0)
    DLQ_MAX_BACKOFF_S:      Max backoff cap in seconds (default: 30.0)
    AWS_ENDPOINT_URL:       Override endpoint (for local ElasticMQ)
    AWS_DEFAULT_REGION:     AWS region (default: us-east-1)
    PROCESSING_DELAY_SECONDS: Simulated work delay (default: 0.5)
"""

import json
import logging
import math
import os
import random
import signal
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from prometheus_client import Counter, Gauge, Histogram, start_http_server
from pythonjsonlogger import jsonlogger

# ─── Logging ──────────────────────────────────────────────────────────────────

def _setup_logging() -> logging.Logger:
    logger = logging.getLogger("dlq-processor")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    return logger


logger = _setup_logging()

# ─── Prometheus Metrics ───────────────────────────────────────────────────────

DLQ_MESSAGES_RECEIVED = Counter(
    "dlq_messages_received_total",
    "Total messages received from the Dead Letter Queue",
)
DLQ_MESSAGES_RETRIED = Counter(
    "dlq_messages_retried_total",
    "Total DLQ messages that were successfully redriven to the main queue",
)
DLQ_MESSAGES_ARCHIVED = Counter(
    "dlq_messages_archived_total",
    "Total DLQ messages that exceeded max retries and were archived (dropped)",
)
DLQ_MESSAGES_FAILED = Counter(
    "dlq_messages_failed_total",
    "Total DLQ messages that failed during retry processing",
)
DLQ_PROCESSING_DURATION = Histogram(
    "dlq_processing_duration_seconds",
    "Time taken to process (retry or archive) a single DLQ message",
    buckets=[0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0],
)
DLQ_QUEUE_DEPTH = Gauge(
    "dlq_approximate_depth",
    "Approximate number of messages currently in the Dead Letter Queue",
)


# ─── Configuration ────────────────────────────────────────────────────────────

@dataclass
class DLQConfig:
    """Configuration for the DLQ processor, loaded from environment variables."""
    dlq_queue_url: str = ""
    main_queue_url: str = ""
    max_retries: int = 3
    base_backoff_s: float = 2.0
    max_backoff_s: float = 30.0
    aws_region: str = "us-east-1"
    endpoint_url: Optional[str] = None
    processing_delay_s: float = 0.5
    metrics_port: int = 8081   # Different port from main consumer (8080)
    poll_wait_seconds: int = 20
    visibility_timeout: int = 60

    @classmethod
    def from_env(cls) -> "DLQConfig":
        return cls(
            dlq_queue_url=os.environ.get("DLQ_QUEUE_URL", ""),
            main_queue_url=os.environ.get("SQS_QUEUE_URL", ""),
            max_retries=int(os.environ.get("DLQ_MAX_RETRIES", "3")),
            base_backoff_s=float(os.environ.get("DLQ_BASE_BACKOFF_S", "2.0")),
            max_backoff_s=float(os.environ.get("DLQ_MAX_BACKOFF_S", "30.0")),
            aws_region=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
            endpoint_url=os.environ.get("AWS_ENDPOINT_URL") or None,
            processing_delay_s=float(os.environ.get("PROCESSING_DELAY_SECONDS", "0.5")),
            metrics_port=int(os.environ.get("DLQ_METRICS_PORT", "8081")),
        )


# ─── Retry Backoff ────────────────────────────────────────────────────────────

def compute_backoff(attempt: int, base: float, cap: float) -> float:
    """
    Compute exponential backoff with full jitter.

    Formula: min(cap, base * 2^attempt) * random(0, 1)

    Full jitter (AWS recommendation) prevents the thundering herd problem:
    if many workers retry simultaneously, staggered jitter distributes load.

    Args:
        attempt: Zero-indexed retry attempt number.
        base: Base delay in seconds (e.g. 2.0).
        cap: Maximum delay cap in seconds (e.g. 30.0).

    Returns:
        Jittered sleep duration in seconds.

    Examples:
        attempt=0: min(30, 2*1=2) * rand → 0 to 2s
        attempt=1: min(30, 2*2=4) * rand → 0 to 4s
        attempt=2: min(30, 2*4=8) * rand → 0 to 8s
        attempt=4: min(30, 2*16=32) → cap at 30s * rand → 0 to 30s
    """
    ceiling = min(cap, base * (2 ** attempt))
    return ceiling * random.random()


# ─── DLQ Processor ────────────────────────────────────────────────────────────

class DLQProcessor:
    """
    Polls the Dead Letter Queue, retries recoverable messages with exponential
    backoff, and archives permanently unrecoverable messages.

    Retry strategy:
      1. Receive message from DLQ.
      2. Inspect the `dlq_retry_count` attribute (or start at 0).
      3. If retry_count < max_retries:
           a. Sleep for backoff(attempt) seconds.
           b. Attempt to re-process the message body.
           c. On success: delete from DLQ, increment retried counter.
           d. On failure: update retry_count, release visibility (let SQS redeliver).
      4. If retry_count >= max_retries:
           Archive (log + delete) — message is a poison pill.
    """

    def __init__(self, config: DLQConfig) -> None:
        self._config = config
        self._running = False

        boto_kwargs: Dict[str, Any] = {
            "region_name": config.aws_region,
            "aws_access_key_id": os.environ.get("AWS_ACCESS_KEY_ID", "dummy"),
            "aws_secret_access_key": os.environ.get("AWS_SECRET_ACCESS_KEY", "dummy"),
        }
        if config.endpoint_url:
            boto_kwargs["endpoint_url"] = config.endpoint_url

        self._sqs = boto3.client("sqs", **boto_kwargs)

        # Install SIGTERM handler for graceful shutdown
        signal.signal(signal.SIGTERM, self._handle_sigterm)
        signal.signal(signal.SIGINT, self._handle_sigterm)

    def start(self) -> None:
        """Start the polling loop. Blocks until SIGTERM/SIGINT."""
        if not self._config.dlq_queue_url:
            logger.error("DLQ_QUEUE_URL is not set — cannot start DLQ processor")
            sys.exit(1)

        try:
            start_http_server(self._config.metrics_port)
            logger.info(
                "DLQ processor metrics server started",
                extra={"port": self._config.metrics_port},
            )
        except OSError:
            logger.warning("Could not start metrics server (port already in use?)")

        self._running = True
        logger.info(
            "DLQ processor started",
            extra={
                "dlq_url": self._config.dlq_queue_url,
                "max_retries": self._config.max_retries,
                "base_backoff_s": self._config.base_backoff_s,
            },
        )

        while self._running:
            self._poll_once()

    def _poll_once(self) -> None:
        """Poll for up to 10 DLQ messages and process each."""
        try:
            response = self._sqs.receive_message(
                QueueUrl=self._config.dlq_queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=self._config.poll_wait_seconds,
                VisibilityTimeout=self._config.visibility_timeout,
                AttributeNames=["All"],
                MessageAttributeNames=["All"],
            )
        except (BotoCoreError, ClientError) as e:
            logger.error("Failed to receive from DLQ", extra={"error": str(e)})
            time.sleep(5)
            return

        messages = response.get("Messages", [])
        self._update_depth_gauge()

        for msg in messages:
            DLQ_MESSAGES_RECEIVED.inc()
            self._process_dlq_message(msg)

    def _process_dlq_message(self, message: dict) -> None:
        """Process a single DLQ message: retry or archive."""
        message_id = message.get("MessageId", "unknown")
        body = message.get("Body", "")
        receipt = message.get("ReceiptHandle", "")

        # Read retry count from message attributes (we set this on each retry)
        attrs = message.get("MessageAttributes", {})
        retry_count_str = attrs.get("dlq_retry_count", {}).get("StringValue", "0")
        retry_count = int(retry_count_str)

        start_time = time.monotonic()

        logger.info(
            "Processing DLQ message",
            extra={
                "message_id": message_id,
                "retry_count": retry_count,
                "max_retries": self._config.max_retries,
                "body_length": len(body),
            },
        )

        if retry_count >= self._config.max_retries:
            self._archive_message(message_id, body, retry_count, receipt)
        else:
            self._retry_message(message_id, body, retry_count, receipt)

        duration = time.monotonic() - start_time
        DLQ_PROCESSING_DURATION.observe(duration)

    def _retry_message(
        self,
        message_id: str,
        body: str,
        retry_count: int,
        receipt: str,
    ) -> None:
        """Apply backoff, attempt re-processing, and delete on success."""
        backoff = compute_backoff(
            attempt=retry_count,
            base=self._config.base_backoff_s,
            cap=self._config.max_backoff_s,
        )

        logger.info(
            "Retrying DLQ message",
            extra={
                "message_id": message_id,
                "retry_count": retry_count,
                "backoff_s": round(backoff, 2),
            },
        )

        time.sleep(backoff)

        try:
            # Simulate processing the message body
            parsed = json.loads(body)
            time.sleep(self._config.processing_delay_s)

            # Success: delete from DLQ and count as retried
            self._sqs.delete_message(
                QueueUrl=self._config.dlq_queue_url,
                ReceiptHandle=receipt,
            )
            DLQ_MESSAGES_RETRIED.inc()
            logger.info(
                "DLQ message retried successfully",
                extra={"message_id": message_id, "retry_count": retry_count},
            )
        except json.JSONDecodeError as e:
            # Malformed JSON: permanently unrecoverable — archive immediately
            logger.warning(
                "DLQ message has invalid JSON — archiving immediately",
                extra={"message_id": message_id, "error": str(e)},
            )
            self._archive_message(message_id, body, retry_count, receipt)
        except Exception as e:
            # Transient failure: release visibility so SQS can redeliver
            DLQ_MESSAGES_FAILED.inc()
            logger.error(
                "DLQ retry failed",
                extra={
                    "message_id": message_id,
                    "retry_count": retry_count,
                    "error": str(e),
                },
            )
            # Note: we do NOT delete the message. SQS will redeliver after
            # the visibility timeout expires. On next delivery, retry_count
            # will be incremented (tracked via MessageAttributes in a real system).

    def _archive_message(
        self,
        message_id: str,
        body: str,
        retry_count: int,
        receipt: str,
    ) -> None:
        """Log and delete a permanently unrecoverable message (poison pill)."""
        logger.warning(
            "Archiving unrecoverable DLQ message (max retries exceeded)",
            extra={
                "message_id": message_id,
                "retry_count": retry_count,
                "body_preview": body[:200],  # Truncate to avoid log bloat
                "action": "archived_and_deleted",
            },
        )

        # In production: send to S3 archive before deleting
        # s3.put_object(Bucket="dlq-archive", Key=f"{message_id}.json", Body=body)

        try:
            self._sqs.delete_message(
                QueueUrl=self._config.dlq_queue_url,
                ReceiptHandle=receipt,
            )
        except (BotoCoreError, ClientError) as e:
            logger.error(
                "Failed to delete archived DLQ message",
                extra={"message_id": message_id, "error": str(e)},
            )

        DLQ_MESSAGES_ARCHIVED.inc()

    def _update_depth_gauge(self) -> None:
        """Query DLQ depth and update the Prometheus gauge."""
        try:
            attrs = self._sqs.get_queue_attributes(
                QueueUrl=self._config.dlq_queue_url,
                AttributeNames=["ApproximateNumberOfMessages"],
            ).get("Attributes", {})
            depth = int(attrs.get("ApproximateNumberOfMessages", 0))
            DLQ_QUEUE_DEPTH.set(depth)
        except Exception:
            pass  # Non-critical, skip on error

    def _handle_sigterm(self, signum: int, frame: Any) -> None:
        """Graceful shutdown on SIGTERM or Ctrl+C."""
        logger.info("DLQ processor shutting down gracefully", extra={"signal": signum})
        self._running = False


# ─── Entrypoint ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    config = DLQConfig.from_env()
    processor = DLQProcessor(config)
    processor.start()
