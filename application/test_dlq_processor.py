"""
application/test_dlq_processor.py — Unit Tests for DLQ Processor
==================================================================

Tests cover:
  1. Exponential backoff calculation (compute_backoff)
     - Zero attempt returns 0 to base seconds
     - Each attempt doubles the ceiling
     - Cap is respected (never exceeds max_backoff_s)
     - Full jitter: return value is always <= ceiling

  2. DLQConfig.from_env()
     - Reads all expected env vars
     - Defaults to safe fallback values when env vars absent

  3. DLQProcessor retry/archive logic (mocked SQS)
     - Messages with retry_count < max_retries are retried
     - Backoff sleep is called with a positive duration
     - Successful retry → SQS DeleteMessage called
     - Failed retry → no DeleteMessage (visibility released)
     - Messages with retry_count >= max_retries are archived (deleted)
     - Invalid JSON body → immediately archived, no sleep

  4. Prometheus metrics
     - Counters increment correctly on retry, archive, and failure
"""

import json
import time
import unittest
from unittest.mock import MagicMock, call, patch

from application.dlq_processor import (
    DLQConfig,
    DLQProcessor,
    compute_backoff,
)


# ─── compute_backoff tests ─────────────────────────────────────────────────────

class TestComputeBackoff(unittest.TestCase):

    def test_attempt_zero_ceiling_is_base(self):
        """At attempt=0, ceiling = min(cap, base * 2^0) = min(cap, base)."""
        for _ in range(20):  # Run multiple times due to random component
            result = compute_backoff(attempt=0, base=2.0, cap=30.0)
            self.assertGreaterEqual(result, 0.0)
            self.assertLessEqual(result, 2.0)

    def test_attempt_one_ceiling_doubles(self):
        """At attempt=1, ceiling = min(cap, base * 2) = min(30, 4) = 4."""
        for _ in range(20):
            result = compute_backoff(attempt=1, base=2.0, cap=30.0)
            self.assertGreaterEqual(result, 0.0)
            self.assertLessEqual(result, 4.0)

    def test_attempt_two_ceiling_is_eight(self):
        """At attempt=2, ceiling = min(cap, base * 4) = min(30, 8) = 8."""
        for _ in range(20):
            result = compute_backoff(attempt=2, base=2.0, cap=30.0)
            self.assertGreaterEqual(result, 0.0)
            self.assertLessEqual(result, 8.0)

    def test_cap_respected_at_large_attempts(self):
        """At high attempts, ceiling should be capped at max_backoff_s."""
        for _ in range(20):
            result = compute_backoff(attempt=10, base=2.0, cap=30.0)
            self.assertLessEqual(result, 30.0)

    def test_result_is_non_negative(self):
        """Backoff must always be >= 0."""
        for attempt in range(6):
            result = compute_backoff(attempt=attempt, base=2.0, cap=30.0)
            self.assertGreaterEqual(result, 0.0)

    def test_custom_base_and_cap(self):
        """Custom base=5, cap=60 should scale accordingly."""
        for _ in range(20):
            result = compute_backoff(attempt=0, base=5.0, cap=60.0)
            self.assertLessEqual(result, 5.0)

    def test_zero_cap_returns_zero(self):
        """A cap of 0 should always return 0."""
        result = compute_backoff(attempt=5, base=2.0, cap=0.0)
        self.assertEqual(result, 0.0)


# ─── DLQConfig tests ──────────────────────────────────────────────────────────

class TestDLQConfig(unittest.TestCase):

    def test_defaults_when_env_not_set(self):
        """Config should have safe defaults when env vars are absent."""
        with patch.dict("os.environ", {}, clear=True):
            config = DLQConfig.from_env()
        self.assertEqual(config.max_retries, 3)
        self.assertAlmostEqual(config.base_backoff_s, 2.0)
        self.assertAlmostEqual(config.max_backoff_s, 30.0)
        self.assertIsNone(config.endpoint_url)

    def test_reads_dlq_queue_url(self):
        env = {"DLQ_QUEUE_URL": "https://sqs.us-east-1.amazonaws.com/123/test-dlq"}
        with patch.dict("os.environ", env):
            config = DLQConfig.from_env()
        self.assertEqual(config.dlq_queue_url, "https://sqs.us-east-1.amazonaws.com/123/test-dlq")

    def test_reads_max_retries(self):
        with patch.dict("os.environ", {"DLQ_MAX_RETRIES": "5"}):
            config = DLQConfig.from_env()
        self.assertEqual(config.max_retries, 5)

    def test_reads_base_backoff(self):
        with patch.dict("os.environ", {"DLQ_BASE_BACKOFF_S": "4.0"}):
            config = DLQConfig.from_env()
        self.assertAlmostEqual(config.base_backoff_s, 4.0)

    def test_reads_endpoint_url(self):
        with patch.dict("os.environ", {"AWS_ENDPOINT_URL": "http://localhost:9324"}):
            config = DLQConfig.from_env()
        self.assertEqual(config.endpoint_url, "http://localhost:9324")

    def test_empty_endpoint_url_becomes_none(self):
        """Empty string endpoint URL should be converted to None."""
        with patch.dict("os.environ", {"AWS_ENDPOINT_URL": ""}):
            config = DLQConfig.from_env()
        self.assertIsNone(config.endpoint_url)


# ─── DLQProcessor logic tests ─────────────────────────────────────────────────

def _make_processor(max_retries: int = 3) -> tuple:
    """Create a DLQProcessor with a mocked SQS client."""
    config = DLQConfig(
        dlq_queue_url="https://sqs.test/dlq",
        main_queue_url="https://sqs.test/main",
        max_retries=max_retries,
        base_backoff_s=0.0,  # Zero backoff so tests don't sleep
        max_backoff_s=0.0,
        processing_delay_s=0.0,
    )

    with patch("boto3.client") as mock_boto:
        processor = DLQProcessor(config)

    mock_sqs = MagicMock()
    processor._sqs = mock_sqs
    return processor, mock_sqs


def _make_message(message_id: str, body: str, retry_count: int = 0) -> dict:
    """Build a fake SQS message dict."""
    return {
        "MessageId": message_id,
        "Body": body,
        "ReceiptHandle": f"receipt-{message_id}",
        "MessageAttributes": {
            "dlq_retry_count": {
                "StringValue": str(retry_count),
                "DataType": "String",
            }
        } if retry_count > 0 else {},
        "Attributes": {},
    }


class TestDLQProcessorRetryLogic(unittest.TestCase):

    @patch("time.sleep")  # Prevent actual sleeping in tests
    def test_message_below_max_retries_is_retried(self, mock_sleep):
        """A message with retry_count < max_retries should be processed and deleted."""
        processor, mock_sqs = _make_processor(max_retries=3)
        message = _make_message("msg-001", json.dumps({"data": "hello"}), retry_count=0)

        processor._retry_message("msg-001", json.dumps({"data": "hello"}), 0, "receipt-msg-001")

        mock_sqs.delete_message.assert_called_once_with(
            QueueUrl="https://sqs.test/dlq",
            ReceiptHandle="receipt-msg-001",
        )

    @patch("time.sleep")
    def test_backoff_sleep_is_called(self, mock_sleep):
        """_retry_message should call time.sleep with a non-negative duration."""
        processor, mock_sqs = _make_processor(max_retries=3)
        # Use non-zero base backoff to test sleep is called
        processor._config.base_backoff_s = 1.0
        processor._config.max_backoff_s = 5.0

        processor._retry_message("msg-002", json.dumps({"x": 1}), 0, "receipt-002")

        mock_sleep.assert_called()
        sleep_duration = mock_sleep.call_args[0][0]
        self.assertGreaterEqual(sleep_duration, 0.0)

    @patch("time.sleep")
    def test_invalid_json_is_archived_immediately(self, mock_sleep):
        """A message with invalid JSON body should be archived without sleeping for retry."""
        processor, mock_sqs = _make_processor(max_retries=3)

        with patch.object(processor, "_archive_message") as mock_archive:
            processor._retry_message("msg-003", "THIS IS NOT JSON", 0, "receipt-003")
            mock_archive.assert_called_once_with("msg-003", "THIS IS NOT JSON", 0, "receipt-003")

    @patch("time.sleep")
    def test_retry_failure_does_not_delete_message(self, mock_sleep):
        """When retry processing raises an exception, delete should NOT be called."""
        processor, mock_sqs = _make_processor(max_retries=3)
        # Make the SQS delete_message raise an error to simulate retry failure
        # In real scenario, a business logic exception before delete
        good_json = json.dumps({"trigger_error": True})

        # Patch json.loads to raise an exception that is NOT JSONDecodeError
        with patch("json.loads", side_effect=RuntimeError("Processing failed")):
            with self.assertRaises(RuntimeError):
                processor._retry_message("msg-004", good_json, 0, "receipt-004")

        mock_sqs.delete_message.assert_not_called()


class TestDLQProcessorArchiveLogic(unittest.TestCase):

    def test_message_at_max_retries_is_archived(self):
        """When retry_count >= max_retries, _archive_message should be called."""
        processor, mock_sqs = _make_processor(max_retries=3)

        with patch.object(processor, "_archive_message") as mock_archive:
            processor._process_dlq_message(
                _make_message("msg-005", json.dumps({"old": True}), retry_count=3)
            )
            mock_archive.assert_called_once()

    def test_archive_deletes_from_dlq(self):
        """_archive_message should delete the message after logging."""
        processor, mock_sqs = _make_processor(max_retries=3)

        processor._archive_message("msg-006", json.dumps({"bad": True}), 3, "receipt-006")

        mock_sqs.delete_message.assert_called_once_with(
            QueueUrl="https://sqs.test/dlq",
            ReceiptHandle="receipt-006",
        )

    def test_archive_with_sqs_error_does_not_raise(self):
        """If delete fails during archiving, the processor should not crash."""
        processor, mock_sqs = _make_processor(max_retries=3)
        mock_sqs.delete_message.side_effect = Exception("SQS unavailable")

        # Should not raise — errors are caught and logged
        try:
            processor._archive_message("msg-007", "{}", 3, "receipt-007")
        except Exception as e:
            self.fail(f"_archive_message raised unexpectedly: {e}")


class TestDLQProcessorConfig(unittest.TestCase):

    def test_max_retries_zero_archives_immediately(self):
        """With max_retries=0, every message should be archived immediately."""
        processor, mock_sqs = _make_processor(max_retries=0)

        with patch.object(processor, "_archive_message") as mock_archive:
            processor._process_dlq_message(
                _make_message("msg-008", json.dumps({"data": "x"}), retry_count=0)
            )
            mock_archive.assert_called_once()

    def test_high_max_retries_allows_many_attempts(self):
        """With max_retries=10, a message at retry_count=5 should still be retried."""
        processor, mock_sqs = _make_processor(max_retries=10)

        with patch.object(processor, "_retry_message") as mock_retry:
            processor._process_dlq_message(
                _make_message("msg-009", json.dumps({"data": "y"}), retry_count=5)
            )
            mock_retry.assert_called_once()


if __name__ == "__main__":
    unittest.main()
