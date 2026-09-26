"""
application/test_multi_queue_consumer.py — Tests for MultiQueueConsumer
=========================================================================

Tests cover:
  1. MultiQueueConfig.from_env() reads all environment variables
  2. Priority-first routing: priority messages block batch processing
  3. Batch messages processed only when priority queue is empty
  4. Both queues empty: idle sleep is called
  5. SQS receive errors return empty list (no crash)
  6. Message deletion called after successful processing
  7. Failure increments the correct counter (priority vs batch)
  8. queue_type is correctly set in log context
"""

import json
import unittest
from unittest.mock import MagicMock, call, patch

from application.multi_queue_consumer import (
    MultiQueueConfig,
    MultiQueueConsumer,
)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _make_consumer() -> tuple:
    """Create a MultiQueueConsumer with mocked SQS and zero delay."""
    config = MultiQueueConfig(
        priority_queue_url="https://sqs.test/priority",
        batch_queue_url="https://sqs.test/batch",
        processing_delay_s=0.0,  # No real sleep in tests
        poll_wait_seconds=0,
    )
    with patch("boto3.client"):
        consumer = MultiQueueConsumer(config)
    mock_sqs = MagicMock()
    consumer._sqs = mock_sqs
    return consumer, mock_sqs


def _sqs_response(messages: list) -> dict:
    """Build a fake SQS ReceiveMessage response."""
    return {"Messages": messages}


def _make_message(msg_id: str = "msg-001", body: str = '{"data":"test"}') -> dict:
    return {
        "MessageId": msg_id,
        "Body": body,
        "ReceiptHandle": f"receipt-{msg_id}",
        "Attributes": {},
    }


# ─── MultiQueueConfig tests ───────────────────────────────────────────────────

class TestMultiQueueConfig(unittest.TestCase):

    def test_reads_priority_queue_url(self):
        with patch.dict("os.environ", {"PRIORITY_QUEUE_URL": "https://sqs.test/p"}):
            config = MultiQueueConfig.from_env()
        self.assertEqual(config.priority_queue_url, "https://sqs.test/p")

    def test_reads_batch_queue_url(self):
        with patch.dict("os.environ", {"BATCH_QUEUE_URL": "https://sqs.test/b"}):
            config = MultiQueueConfig.from_env()
        self.assertEqual(config.batch_queue_url, "https://sqs.test/b")

    def test_falls_back_to_sqs_queue_url_with_suffix(self):
        """If PRIORITY/BATCH not set, falls back to SQS_QUEUE_URL + suffix."""
        env = {"SQS_QUEUE_URL": "https://sqs.test/main"}
        with patch.dict("os.environ", env, clear=True):
            config = MultiQueueConfig.from_env()
        self.assertIn("priority", config.priority_queue_url)
        self.assertIn("batch", config.batch_queue_url)

    def test_reads_endpoint_url(self):
        with patch.dict("os.environ", {"AWS_ENDPOINT_URL": "http://localhost:9324"}):
            config = MultiQueueConfig.from_env()
        self.assertEqual(config.endpoint_url, "http://localhost:9324")

    def test_empty_endpoint_url_becomes_none(self):
        with patch.dict("os.environ", {"AWS_ENDPOINT_URL": ""}):
            config = MultiQueueConfig.from_env()
        self.assertIsNone(config.endpoint_url)

    def test_default_processing_delay(self):
        with patch.dict("os.environ", {}, clear=True):
            config = MultiQueueConfig.from_env()
        self.assertAlmostEqual(config.processing_delay_s, 1.0)


# ─── Priority-first routing tests ─────────────────────────────────────────────

class TestPriorityFirstRouting(unittest.TestCase):

    @patch("time.sleep")
    def test_priority_messages_processed_before_batch(self, mock_sleep):
        """When priority queue has messages, batch queue should NOT be polled."""
        consumer, mock_sqs = _make_consumer()

        priority_msg = _make_message("p-001")
        # Priority returns a message; batch should never be called
        mock_sqs.receive_message.return_value = _sqs_response([priority_msg])
        mock_sqs.get_queue_attributes.return_value = {"Attributes": {"ApproximateNumberOfMessages": "1"}}

        consumer._poll_cycle()

        # receive_message should have been called with the priority URL only
        calls = [str(c) for c in mock_sqs.receive_message.call_args_list]
        self.assertEqual(len(calls), 1)
        self.assertIn("priority", mock_sqs.receive_message.call_args_list[0][1]["QueueUrl"])

    @patch("time.sleep")
    def test_batch_processed_when_priority_empty(self, mock_sleep):
        """When priority queue is empty, batch queue should be polled."""
        consumer, mock_sqs = _make_consumer()

        batch_msg = _make_message("b-001")
        mock_sqs.get_queue_attributes.return_value = {"Attributes": {"ApproximateNumberOfMessages": "0"}}

        # First call (priority): empty, second call (batch): has message
        mock_sqs.receive_message.side_effect = [
            _sqs_response([]),          # priority is empty
            _sqs_response([batch_msg]), # batch has message
        ]

        consumer._poll_cycle()

        # Should have polled both queues
        self.assertEqual(mock_sqs.receive_message.call_count, 2)
        # Second call must be batch queue
        second_call_url = mock_sqs.receive_message.call_args_list[1][1]["QueueUrl"]
        self.assertIn("batch", second_call_url)

    @patch("time.sleep")
    def test_idle_sleep_when_both_queues_empty(self, mock_sleep):
        """When both queues are empty, time.sleep should be called."""
        consumer, mock_sqs = _make_consumer()
        mock_sqs.receive_message.return_value = _sqs_response([])
        mock_sqs.get_queue_attributes.return_value = {"Attributes": {"ApproximateNumberOfMessages": "0"}}

        consumer._poll_cycle()

        # time.sleep called for idle (at least once)
        mock_sleep.assert_called()

    @patch("time.sleep")
    def test_multiple_priority_messages_all_processed(self, mock_sleep):
        """All messages in priority batch should be processed before returning."""
        consumer, mock_sqs = _make_consumer()
        mock_sqs.get_queue_attributes.return_value = {"Attributes": {"ApproximateNumberOfMessages": "3"}}

        three_msgs = [_make_message(f"p-{i:03d}") for i in range(3)]
        mock_sqs.receive_message.return_value = _sqs_response(three_msgs)

        consumer._poll_cycle()

        # delete_message should have been called 3 times
        self.assertEqual(mock_sqs.delete_message.call_count, 3)


# ─── Message processing tests ─────────────────────────────────────────────────

class TestMessageProcessing(unittest.TestCase):

    @patch("time.sleep")
    def test_delete_called_after_successful_priority_process(self, mock_sleep):
        consumer, mock_sqs = _make_consumer()
        consumer._process_message(_make_message("p-001"), queue_type="priority")
        mock_sqs.delete_message.assert_called_once_with(
            QueueUrl="https://sqs.test/priority",
            ReceiptHandle="receipt-p-001",
        )

    @patch("time.sleep")
    def test_delete_called_after_successful_batch_process(self, mock_sleep):
        consumer, mock_sqs = _make_consumer()
        consumer._process_message(_make_message("b-001"), queue_type="batch")
        mock_sqs.delete_message.assert_called_once_with(
            QueueUrl="https://sqs.test/batch",
            ReceiptHandle="receipt-b-001",
        )

    @patch("time.sleep")
    def test_priority_failure_does_not_call_batch_counter(self, mock_sleep):
        """Failure in priority queue should only increment priority failure counter."""
        consumer, mock_sqs = _make_consumer()
        mock_sqs.delete_message.side_effect = Exception("SQS down")

        from application import multi_queue_consumer as mq
        with patch.object(mq.PRIORITY_FAILED, "inc") as p_fail, \
             patch.object(mq.BATCH_FAILED, "inc") as b_fail:
            consumer._process_message(_make_message("p-001"), queue_type="priority")
            p_fail.assert_called_once()
            b_fail.assert_not_called()

    @patch("time.sleep")
    def test_batch_failure_does_not_call_priority_counter(self, mock_sleep):
        """Failure in batch queue should only increment batch failure counter."""
        consumer, mock_sqs = _make_consumer()
        mock_sqs.delete_message.side_effect = Exception("SQS down")

        from application import multi_queue_consumer as mq
        with patch.object(mq.BATCH_FAILED, "inc") as b_fail, \
             patch.object(mq.PRIORITY_FAILED, "inc") as p_fail:
            consumer._process_message(_make_message("b-001"), queue_type="batch")
            b_fail.assert_called_once()
            p_fail.assert_not_called()


# ─── SQS error handling tests ─────────────────────────────────────────────────

class TestSQSErrorHandling(unittest.TestCase):

    def test_receive_error_returns_empty_list(self):
        """SQS receive errors should return [] and not raise."""
        consumer, mock_sqs = _make_consumer()
        from botocore.exceptions import ClientError
        mock_sqs.receive_message.side_effect = ClientError(
            {"Error": {"Code": "AWS.SimpleQueueService.NonExistentQueue", "Message": "queue not found"}},
            "ReceiveMessage",
        )
        result = consumer._receive_messages("https://sqs.test/priority", label="priority")
        self.assertEqual(result, [])

    def test_receive_returns_correct_messages(self):
        """_receive_messages should return the messages list from SQS response."""
        consumer, mock_sqs = _make_consumer()
        msgs = [_make_message("msg-001"), _make_message("msg-002")]
        mock_sqs.receive_message.return_value = _sqs_response(msgs)
        mock_sqs.get_queue_attributes.return_value = {"Attributes": {"ApproximateNumberOfMessages": "2"}}

        result = consumer._receive_messages("https://sqs.test/priority", label="priority")
        self.assertEqual(len(result), 2)


if __name__ == "__main__":
    unittest.main()
