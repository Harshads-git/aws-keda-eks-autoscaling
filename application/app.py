"""
app.py — AWS SQS Consumer for KEDA Event-Driven Autoscaling Demo
=================================================================
AWS port of the GCP Pub/Sub consumer from:
  github.com/ChimbuChinnadurai/gcp-keda-gke-event-driven-autoscaling-demo

GCP original used:
  google.cloud.pubsub_v1.SubscriberClient
  subscriber.subscribe(subscription_path, callback=process_payload)
  message.ack()

This AWS version uses:
  boto3 SQS client
  sqs.receive_message() — long polling loop
  sqs.delete_message()  — explicit delete after successful processing

The consumer is designed to run as a Kubernetes Deployment that KEDA scales
from 0 → N replicas based on SQS queue depth (ApproximateNumberOfMessages).
When the queue is empty, KEDA scales replicas back to 0 (scale to zero).

Key design decisions:
  - Graceful shutdown: SIGTERM handler finishes current message before exit
  - Structured JSON logging: compatible with CloudWatch Logs Insights queries
  - Long polling: 20s wait reduces API calls and cost vs short polling
  - Health check file: /tmp/healthy signals readiness to Kubernetes HEALTHCHECK
  - Single-threaded: one message per iteration for predictable KEDA scaling
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from pythonjsonlogger import jsonlogger

# ─── Logging Setup ────────────────────────────────────────────────────────────

def setup_logging(level: str = "INFO") -> logging.Logger:
    """
    Configure structured JSON logging for CloudWatch Logs Insights.

    JSON format enables powerful CloudWatch queries like:
      fields @timestamp, message, message_id, duration_ms
      | filter level = "ERROR"
      | sort @timestamp desc

    GCP equivalent: Cloud Logging structured log format
    """
    logger = logging.getLogger("keda-demo")
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))

    # Remove any existing handlers (avoids duplicate logs in tests)
    logger.handlers.clear()

    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    return logger


# ─── Configuration ────────────────────────────────────────────────────────────

def load_config() -> dict[str, Any]:
    """
    Load all configuration from environment variables.

    GCP reference used: PUB_SUB_TOPIC, PUB_SUB_PROJECT, PUB_SUB_SUBSCRIPTION
    AWS equivalent:     SQS_QUEUE_URL, AWS_REGION

    All config from environment — 12-factor app principle (Factor III).
    In Kubernetes, these come from ConfigMap (non-sensitive) or Secrets (sensitive).
    IRSA handles AWS credentials automatically — no AWS keys in env vars.
    """
    queue_url = os.environ.get("SQS_QUEUE_URL", "").strip()
    if not queue_url:
        raise EnvironmentError(
            "SQS_QUEUE_URL environment variable is required. "
            "Set it to your SQS queue URL, e.g.: "
            "https://sqs.us-east-1.amazonaws.com/123456789012/keda-demo-queue"
        )

    return {
        "queue_url":          queue_url,
        "aws_region":         os.environ.get("AWS_REGION", "us-east-1"),
        "log_level":          os.environ.get("LOG_LEVEL", "INFO"),
        "wait_time_seconds":  int(os.environ.get("SQS_WAIT_TIME_SECONDS", "20")),
        "max_messages":       int(os.environ.get("SQS_MAX_MESSAGES", "1")),
        "visibility_timeout": int(os.environ.get("SQS_VISIBILITY_TIMEOUT", "30")),
        "health_file":        os.environ.get("HEALTH_FILE", "/tmp/healthy"),
        "shutdown_timeout":   int(os.environ.get("SHUTDOWN_TIMEOUT_SECONDS", "30")),
    }


# ─── Message Processing ───────────────────────────────────────────────────────

def process_message(message: dict[str, Any], logger: logging.Logger) -> bool:
    """
    Process a single SQS message.

    GCP original:
        def process_payload(message):
            print(f"Received {message.data}.")
            message.ack()    # ack = delete in Pub/Sub

    AWS equivalent:
        def process_message(message):
            body = message["Body"]
            # ... process ...
            sqs.delete_message(ReceiptHandle=message["ReceiptHandle"])

    The key difference: in SQS we do NOT delete here — deletion is done
    by the caller ONLY after this function returns True (success). This
    separation ensures at-least-once processing: if the pod crashes after
    processing but before deleting, the message reappears after VisibilityTimeout.

    Returns:
        True  — processing succeeded, caller should delete the message
        False — processing failed, caller should NOT delete (let it retry or go to DLQ)
    """
    message_id   = message.get("MessageId", "unknown")
    receipt      = message.get("ReceiptHandle", "")
    body         = message.get("Body", "")
    attributes   = message.get("Attributes", {})
    receive_count = int(attributes.get("ApproximateReceiveCount", 1))

    start_time = time.monotonic()

    logger.info(
        "Processing message",
        extra={
            "message_id":    message_id,
            "receive_count": receive_count,
            "body_length":   len(body),
        },
    )

    try:
        # ── Core processing logic ─────────────────────────────────────────────
        # In a real system this would be: database write, HTTP call, file transform, etc.
        # For this demo: log the message body (same as the GCP reference app)
        logger.info(
            f"Received message: {body}",
            extra={"message_id": message_id, "body": body},
        )

        # Simulate brief processing time (remove in real implementations)
        time.sleep(0.1)

        duration_ms = round((time.monotonic() - start_time) * 1000, 2)
        logger.info(
            "Message processed successfully",
            extra={
                "message_id":  message_id,
                "duration_ms": duration_ms,
            },
        )
        return True

    except Exception as exc:  # noqa: BLE001
        duration_ms = round((time.monotonic() - start_time) * 1000, 2)
        logger.error(
            "Message processing failed",
            extra={
                "message_id":    message_id,
                "receive_count": receive_count,
                "duration_ms":   duration_ms,
                "error":         str(exc),
                "error_type":    type(exc).__name__,
            },
            exc_info=True,
        )
        return False


# ─── SQS Consumer ─────────────────────────────────────────────────────────────

class SQSConsumer:
    """
    Long-polling SQS consumer that KEDA scales based on queue depth.

    Lifecycle:
        1. Start:     Create SQS client, write /tmp/healthy, begin polling loop
        2. Poll:      receive_message (long poll, 20s wait)
        3. Process:   call process_message()
        4. Ack/Nack:  delete on success, leave for retry on failure
        5. Shutdown:  SIGTERM → finish current message → exit cleanly

    KEDA scaling interaction:
        - Queue empty  → KEDA sees 0 messages → scales to 0 replicas (this pod terminates)
        - Queue filling → KEDA sees N messages → scales to ceil(N/5) replicas
        - Multiple pods run simultaneously, each picking 1 message at a time
    """

    def __init__(self, config: dict[str, Any], logger: logging.Logger) -> None:
        self.config  = config
        self.logger  = logger
        self._running = True
        self._processing = False

        # Create the boto3 SQS client
        # IRSA: credentials come from projected ServiceAccount token via STS
        # No AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY needed
        self.sqs = boto3.client("sqs", region_name=config["aws_region"])

    def _setup_signal_handlers(self) -> None:
        """
        Register SIGTERM and SIGINT handlers for graceful shutdown.

        Critical for Kubernetes: when a pod is deleted, K8s sends SIGTERM.
        We must finish the current message before exiting — otherwise the
        message will reappear after VisibilityTimeout and be processed again
        (causing duplicates in some scenarios).

        GCP Pub/Sub handles this differently: unacked messages are
        automatically redelivered by the broker. SQS relies on VisibilityTimeout.
        """
        def _handler(signum: int, _frame: Any) -> None:
            sig_name = signal.Signals(signum).name
            self.logger.info(
                f"Received {sig_name} — initiating graceful shutdown",
                extra={"signal": sig_name, "processing": self._processing},
            )
            self._running = False

        signal.signal(signal.SIGTERM, _handler)
        signal.signal(signal.SIGINT,  _handler)
        self.logger.info("Signal handlers registered (SIGTERM, SIGINT)")

    def _write_health_file(self) -> None:
        """
        Create /tmp/healthy to signal readiness to Kubernetes HEALTHCHECK.

        The Dockerfile HEALTHCHECK checks for this file:
            CMD python -c "import os,sys; sys.exit(0 if os.path.exists('/tmp/healthy') else 1)"
        """
        try:
            with open(self.config["health_file"], "w") as f:
                f.write("ok\n")
            self.logger.info(
                "Health file created",
                extra={"path": self.config["health_file"]},
            )
        except OSError as e:
            self.logger.warning(
                "Could not write health file",
                extra={"path": self.config["health_file"], "error": str(e)},
            )

    def _remove_health_file(self) -> None:
        """Remove health file on shutdown so K8s marks pod as unhealthy."""
        try:
            os.remove(self.config["health_file"])
        except OSError:
            pass

    def _delete_message(self, receipt_handle: str, message_id: str) -> None:
        """
        Delete a successfully processed message from SQS.

        GCP equivalent: message.ack()
        SQS equivalent: sqs.delete_message(ReceiptHandle=...)

        The ReceiptHandle is unique per receive — if you receive the same
        message twice (after VisibilityTimeout), you get a NEW ReceiptHandle.
        This prevents accidental deletion of messages being processed elsewhere.
        """
        try:
            self.sqs.delete_message(
                QueueUrl=self.config["queue_url"],
                ReceiptHandle=receipt_handle,
            )
            self.logger.debug(
                "Message deleted from queue",
                extra={"message_id": message_id},
            )
        except ClientError as e:
            self.logger.error(
                "Failed to delete message — it will reappear after VisibilityTimeout",
                extra={
                    "message_id": message_id,
                    "error":      str(e),
                    "error_code": e.response["Error"]["Code"],
                },
            )

    def run(self) -> None:
        """
        Main polling loop — runs until SIGTERM received.

        Long polling (WaitTimeSeconds=20) means:
          - SQS holds the connection open for up to 20s waiting for a message
          - If a message arrives, returns immediately (no 20s wait)
          - If nothing arrives in 20s, returns empty → we loop again
          - Reduces empty ReceiveMessage calls from ~3,600/hr to ~180/hr
        """
        self._setup_signal_handlers()
        self._write_health_file()

        self.logger.info(
            "SQS consumer started",
            extra={
                "queue_url":       self.config["queue_url"],
                "aws_region":      self.config["aws_region"],
                "wait_time":       self.config["wait_time_seconds"],
                "max_messages":    self.config["max_messages"],
            },
        )

        empty_poll_count = 0

        while self._running:
            try:
                # ── Receive message (long polling) ────────────────────────────
                response = self.sqs.receive_message(
                    QueueUrl=self.config["queue_url"],
                    MaxNumberOfMessages=self.config["max_messages"],
                    WaitTimeSeconds=self.config["wait_time_seconds"],
                    AttributeNames=["All"],
                    MessageAttributeNames=["All"],
                )

                messages = response.get("Messages", [])

                if not messages:
                    empty_poll_count += 1
                    self.logger.debug(
                        "No messages received (queue may be empty)",
                        extra={"empty_poll_count": empty_poll_count},
                    )
                    # When queue is empty for multiple cycles, KEDA will
                    # scale this pod to 0. The loop keeps running briefly
                    # until SIGTERM arrives from Kubernetes pod termination.
                    continue

                empty_poll_count = 0

                # ── Process each message ──────────────────────────────────────
                for message in messages:
                    if not self._running:
                        # SIGTERM received mid-batch — stop processing new messages
                        self.logger.info("Shutdown signal received mid-batch — stopping")
                        break

                    self._processing = True
                    message_id    = message.get("MessageId", "unknown")
                    receipt       = message.get("ReceiptHandle", "")

                    success = process_message(message, self.logger)

                    if success:
                        self._delete_message(receipt, message_id)
                    else:
                        # Leave message in queue — SQS will redeliver after VisibilityTimeout
                        # After maxReceiveCount failures, SQS moves it to the DLQ
                        self.logger.warning(
                            "Message not deleted — will retry or go to DLQ",
                            extra={"message_id": message_id},
                        )

                    self._processing = False

            except ClientError as e:
                error_code = e.response["Error"]["Code"]
                self.logger.error(
                    "SQS API error during receive",
                    extra={"error_code": error_code, "error": str(e)},
                )
                # Back off before retrying to avoid hammering AWS APIs on errors
                time.sleep(5)

            except (BotoCoreError, Exception) as e:  # noqa: BLE001
                self.logger.error(
                    "Unexpected error in polling loop",
                    extra={"error": str(e), "error_type": type(e).__name__},
                    exc_info=True,
                )
                time.sleep(5)

        # ── Graceful shutdown ─────────────────────────────────────────────────
        self._remove_health_file()
        self.logger.info("SQS consumer shut down cleanly")


# ─── Entry Point ──────────────────────────────────────────────────────────────

def main() -> None:
    """Application entry point."""
    # Load config first (will raise EnvironmentError if SQS_QUEUE_URL missing)
    try:
        config = load_config()
    except EnvironmentError as e:
        # Can't use structured logger yet — config load failed
        print(json.dumps({"level": "CRITICAL", "message": str(e)}), flush=True)
        sys.exit(1)

    logger = setup_logging(config["log_level"])

    logger.info(
        "Starting KEDA demo SQS consumer",
        extra={
            "version":    "1.0.0",
            "queue_url":  config["queue_url"],
            "aws_region": config["aws_region"],
        },
    )

    consumer = SQSConsumer(config, logger)
    consumer.run()


if __name__ == "__main__":
    main()
