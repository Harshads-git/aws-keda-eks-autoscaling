"""
application/multi_queue_consumer.py — Priority-Aware Multi-Queue SQS Consumer
===============================================================================

Polls two SQS queues (priority and batch) from a single pod with priority
routing: the priority queue is always drained first before any batch messages
are processed.

Architecture:
  KEDA ScaledObject (multi-queue-scaled-object.yaml) scales this Deployment
  based on the combined depth of both queues. Each pod runs this consumer
  which implements the following polling loop:

  Priority-First Polling Loop:
  ┌─────────────────────────────────────────────────┐
  │  1. Poll PRIORITY queue (MaxMessages=10)         │
  │     If messages found → process ALL of them     │
  │     then loop back to step 1 (priority first)   │
  │  2. Only if priority queue is EMPTY:            │
  │     Poll BATCH queue (MaxMessages=10)            │
  │     Process batch messages                       │
  │  3. If BOTH queues empty → sleep 1s (idle)      │
  └─────────────────────────────────────────────────┘

Why priority-first (not round-robin)?
  Round-robin: 50% of pod time goes to batch even during a priority spike.
    Priority SLA would be violated during combined high-load periods.
  Priority-first: 100% of pod time goes to priority when priority > 0.
    Batch processing pauses during priority spikes, resumes when drained.
    Acceptable because batch has no latency SLO (throughput-optimised).

Trade-off: batch starvation.
  If the priority queue never empties, batch messages wait indefinitely.
  Mitigation: separate maxReplicaCount between consumers, or add time-based
  batch admission (allow batch every N priority messages) — see docs/multi-queue-guide.md.

Environment Variables:
    PRIORITY_QUEUE_URL: SQS URL for the high-priority queue (required)
    BATCH_QUEUE_URL:    SQS URL for the batch processing queue (required)
    SQS_QUEUE_URL:      Fallback if neither above is set (single-queue mode)
    PRIORITY_TARGET:    Messages per pod for priority queue (default: 2)
    BATCH_TARGET:       Messages per pod for batch queue (default: 10)
    AWS_ENDPOINT_URL:   Override for local ElasticMQ
    PROCESSING_DELAY_SECONDS: Simulated processing time (default: 1.0s)
"""

import logging
import os
import signal
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from prometheus_client import Counter, Gauge, Histogram, start_http_server
from pythonjsonlogger import jsonlogger

# ─── Logging ──────────────────────────────────────────────────────────────────

def _setup_logging() -> logging.Logger:
    logger = logging.getLogger("multi-queue-consumer")
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

PRIORITY_PROCESSED = Counter(
    "mq_priority_messages_processed_total",
    "Total priority-queue messages processed successfully",
)
BATCH_PROCESSED = Counter(
    "mq_batch_messages_processed_total",
    "Total batch-queue messages processed successfully",
)
PRIORITY_FAILED = Counter(
    "mq_priority_messages_failed_total",
    "Total priority-queue messages that failed processing",
)
BATCH_FAILED = Counter(
    "mq_batch_messages_failed_total",
    "Total batch-queue messages that failed processing",
)
PRIORITY_DEPTH = Gauge(
    "mq_priority_queue_depth",
    "Approximate number of messages in the priority queue",
)
BATCH_DEPTH = Gauge(
    "mq_batch_queue_depth",
    "Approximate number of messages in the batch queue",
)
PRIORITY_PROCESSING_DURATION = Histogram(
    "mq_priority_processing_duration_seconds",
    "Processing time per priority message",
    buckets=[0.05, 0.1, 0.5, 1.0, 2.0, 5.0],
)
BATCH_PROCESSING_DURATION = Histogram(
    "mq_batch_processing_duration_seconds",
    "Processing time per batch message",
    buckets=[0.1, 0.5, 1.0, 5.0, 10.0, 30.0],
)


# ─── Configuration ────────────────────────────────────────────────────────────

@dataclass
class MultiQueueConfig:
    priority_queue_url: str
    batch_queue_url: str
    aws_region: str = "us-east-1"
    endpoint_url: Optional[str] = None
    processing_delay_s: float = 1.0
    metrics_port: int = 8080
    poll_wait_seconds: int = 1   # Short wait: priority-first needs responsiveness
    visibility_timeout: int = 30

    @classmethod
    def from_env(cls) -> "MultiQueueConfig":
        base_url = os.environ.get("SQS_QUEUE_URL", "")
        return cls(
            priority_queue_url=os.environ.get("PRIORITY_QUEUE_URL", base_url + "-priority"),
            batch_queue_url=os.environ.get("BATCH_QUEUE_URL", base_url + "-batch"),
            aws_region=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
            endpoint_url=os.environ.get("AWS_ENDPOINT_URL") or None,
            processing_delay_s=float(os.environ.get("PROCESSING_DELAY_SECONDS", "1.0")),
            metrics_port=int(os.environ.get("METRICS_PORT", "8080")),
        )


# ─── Multi-Queue Consumer ─────────────────────────────────────────────────────

class MultiQueueConsumer:
    """
    Priority-first SQS consumer polling two queues from a single pod.

    Implements strict priority scheduling: the priority queue is always
    polled and drained before any batch message is processed.
    """

    def __init__(self, config: MultiQueueConfig) -> None:
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

        signal.signal(signal.SIGTERM, self._handle_sigterm)
        signal.signal(signal.SIGINT, self._handle_sigterm)

    def start(self) -> None:
        """Start the priority-first polling loop. Blocks until SIGTERM."""
        try:
            start_http_server(self._config.metrics_port)
        except OSError:
            logger.warning("Metrics port already in use, skipping metrics server")

        self._running = True
        logger.info(
            "Multi-queue consumer started",
            extra={
                "priority_queue": self._config.priority_queue_url,
                "batch_queue": self._config.batch_queue_url,
                "strategy": "priority-first",
            },
        )

        while self._running:
            self._poll_cycle()

    def _poll_cycle(self) -> None:
        """One iteration of the priority-first polling loop."""
        # Step 1: Always check priority queue first
        priority_msgs = self._receive_messages(
            self._config.priority_queue_url, label="priority"
        )

        if priority_msgs:
            for msg in priority_msgs:
                self._process_message(msg, queue_type="priority")
            # Loop back immediately — don't touch batch while priority has messages
            return

        # Step 2: Priority queue is empty, now process batch
        batch_msgs = self._receive_messages(
            self._config.batch_queue_url, label="batch"
        )

        if batch_msgs:
            for msg in batch_msgs:
                self._process_message(msg, queue_type="batch")
            return

        # Step 3: Both queues empty — idle sleep
        time.sleep(1.0)

    def _receive_messages(self, queue_url: str, label: str) -> List[dict]:
        """Receive up to 10 messages from the given queue. Returns [] on error."""
        try:
            response = self._sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=self._config.poll_wait_seconds,
                VisibilityTimeout=self._config.visibility_timeout,
                AttributeNames=["All"],
            )
            messages = response.get("Messages", [])
            self._update_depth_gauge(queue_url, label)
            return messages
        except (BotoCoreError, ClientError) as e:
            logger.error(
                f"Failed to receive from {label} queue",
                extra={"queue": queue_url, "error": str(e)},
            )
            return []

    def _process_message(self, message: dict, queue_type: str) -> None:
        """Process and delete a single message, recording metrics."""
        message_id = message.get("MessageId", "unknown")
        body = message.get("Body", "")
        receipt = message.get("ReceiptHandle", "")
        queue_url = (
            self._config.priority_queue_url
            if queue_type == "priority"
            else self._config.batch_queue_url
        )

        start = time.monotonic()
        logger.info(
            "Processing message",
            extra={
                "queue_type": queue_type,
                "message_id": message_id,
                "body_length": len(body),
            },
        )

        try:
            # Simulate processing work
            time.sleep(self._config.processing_delay_s)

            self._sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt)

            duration = time.monotonic() - start

            if queue_type == "priority":
                PRIORITY_PROCESSED.inc()
                PRIORITY_PROCESSING_DURATION.observe(duration)
            else:
                BATCH_PROCESSED.inc()
                BATCH_PROCESSING_DURATION.observe(duration)

            logger.info(
                "Message processed",
                extra={
                    "queue_type": queue_type,
                    "message_id": message_id,
                    "duration_ms": round(duration * 1000, 1),
                },
            )

        except Exception as e:
            duration = time.monotonic() - start
            if queue_type == "priority":
                PRIORITY_FAILED.inc()
            else:
                BATCH_FAILED.inc()

            logger.error(
                "Message processing failed",
                extra={
                    "queue_type": queue_type,
                    "message_id": message_id,
                    "error": str(e),
                    "duration_ms": round(duration * 1000, 1),
                },
            )

    def _update_depth_gauge(self, queue_url: str, label: str) -> None:
        """Query the approximate queue depth and update Prometheus gauge."""
        try:
            attrs = self._sqs.get_queue_attributes(
                QueueUrl=queue_url,
                AttributeNames=["ApproximateNumberOfMessages"],
            ).get("Attributes", {})
            depth = int(attrs.get("ApproximateNumberOfMessages", 0))
            if label == "priority":
                PRIORITY_DEPTH.set(depth)
            else:
                BATCH_DEPTH.set(depth)
        except Exception:
            pass

    def _handle_sigterm(self, signum: int, frame: Any) -> None:
        logger.info("Multi-queue consumer shutting down", extra={"signal": signum})
        self._running = False


# ─── Entrypoint ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    config = MultiQueueConfig.from_env()
    consumer = MultiQueueConsumer(config)
    consumer.start()
