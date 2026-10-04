"""
application/test_producer_api.py — Tests for the Producer API
==============================================================

Uses FastAPI TestClient to test all producer endpoints without a
running server or real SQS connection.

Tests cover:
  1. /health returns 200
  2. POST /send with queue_type=priority → calls SQS with priority URL
  3. POST /send with queue_type=batch → calls SQS with batch URL
  4. POST /send with invalid queue_type → 422 validation error
  5. POST /send/bulk sends correct number of messages via batch API
  6. POST /send/bulk uses {index} template substitution correctly
  7. POST /send/bulk with count > BATCH_SIZE uses multiple send_message_batch calls
  8. POST /send/bulk returns sent/failed counts
  9. GET /queue/depth queries both queue URLs
  10. GET /queue/depth returns depth values from SQS
  11. SQS ClientError on /send → 503 response
  12. Response fields: all required fields present
  13. Prometheus metrics updated on send
"""

import json
import unittest
from unittest.mock import MagicMock, patch, call

try:
    from fastapi.testclient import TestClient
    TESTCLIENT_AVAILABLE = True
except ImportError:
    TESTCLIENT_AVAILABLE = False


def _make_client():
    """Create a TestClient with a mocked SQS client."""
    import application.producer_api as api_module

    # Reset global state
    api_module._sqs = None

    mock_sqs = MagicMock()
    # Default SQS responses
    mock_sqs.send_message.return_value = {"MessageId": "test-msg-id-001"}
    mock_sqs.send_message_batch.return_value = {
        "Successful": [{"Id": str(i), "MessageId": f"msg-{i:04d}"} for i in range(10)],
        "Failed": [],
    }
    mock_sqs.get_queue_attributes.return_value = {
        "Attributes": {"ApproximateNumberOfMessages": "5"}
    }

    with patch("boto3.client", return_value=mock_sqs):
        with patch.dict("os.environ", {
            "SQS_QUEUE_URL": "https://sqs.test/main",
            "PRIORITY_QUEUE_URL": "https://sqs.test/priority",
            "BATCH_QUEUE_URL": "https://sqs.test/batch",
        }):
            app = api_module.create_app()

    # Inject mock directly
    api_module._sqs = mock_sqs
    api_module._config.priority_queue_url = "https://sqs.test/priority"
    api_module._config.batch_queue_url = "https://sqs.test/batch"

    return TestClient(app), mock_sqs, api_module


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestHealthEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_sqs, self.api = _make_client()

    def test_health_returns_200(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestSendEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_sqs, self.api = _make_client()

    def test_send_priority_calls_priority_queue(self):
        """POST /send with queue_type=priority should use the priority queue URL."""
        self.mock_sqs.send_message.return_value = {"MessageId": "p-001"}
        response = self.client.post("/send", json={
            "body": '{"event": "test"}',
            "queue_type": "priority",
        })
        self.assertEqual(response.status_code, 200)
        call_kwargs = self.mock_sqs.send_message.call_args[1]
        self.assertEqual(call_kwargs["QueueUrl"], "https://sqs.test/priority")

    def test_send_batch_calls_batch_queue(self):
        """POST /send with queue_type=batch should use the batch queue URL."""
        self.mock_sqs.send_message.return_value = {"MessageId": "b-001"}
        response = self.client.post("/send", json={
            "body": '{"event": "batch-test"}',
            "queue_type": "batch",
        })
        self.assertEqual(response.status_code, 200)
        call_kwargs = self.mock_sqs.send_message.call_args[1]
        self.assertEqual(call_kwargs["QueueUrl"], "https://sqs.test/batch")

    def test_send_invalid_queue_type_returns_422(self):
        """Invalid queue_type should return 422 (Pydantic validation error)."""
        response = self.client.post("/send", json={
            "body": "test",
            "queue_type": "invalid",
        })
        self.assertEqual(response.status_code, 422)

    def test_send_response_has_required_fields(self):
        """Response must include message_id, queue_type, queue_url, send_duration_ms."""
        self.mock_sqs.send_message.return_value = {"MessageId": "abc-123"}
        response = self.client.post("/send", json={"body": "hello"})
        self.assertEqual(response.status_code, 200)
        data = response.json()
        for field in ["message_id", "queue_type", "queue_url", "send_duration_ms"]:
            self.assertIn(field, data, f"Missing: {field}")

    def test_send_default_queue_type_is_priority(self):
        """When queue_type is not specified, should default to priority."""
        self.mock_sqs.send_message.return_value = {"MessageId": "d-001"}
        response = self.client.post("/send", json={"body": "test"})
        data = response.json()
        self.assertEqual(data["queue_type"], "priority")

    def test_send_sqs_error_returns_503(self):
        """SQS ClientError should return 503."""
        from botocore.exceptions import ClientError
        self.mock_sqs.send_message.side_effect = ClientError(
            {"Error": {"Code": "QueueDoesNotExist", "Message": "Queue not found"}},
            "SendMessage",
        )
        response = self.client.post("/send", json={"body": "test"})
        self.assertEqual(response.status_code, 503)


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestBulkSendEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_sqs, self.api = _make_client()

    def test_bulk_send_5_messages_in_one_batch(self):
        """5 messages should fit in one send_message_batch call."""
        self.mock_sqs.send_message_batch.return_value = {
            "Successful": [{"Id": str(i), "MessageId": f"m{i}"} for i in range(5)],
            "Failed": [],
        }
        response = self.client.post("/send/bulk", json={"count": 5})
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["sent"], 5)
        self.assertEqual(data["failed"], 0)

    def test_bulk_send_25_messages_uses_3_batch_calls(self):
        """25 messages need ceil(25/10) = 3 batch API calls."""
        call_count = 0

        def mock_batch(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            n = len(kwargs.get("Entries", []))
            return {
                "Successful": [{"Id": str(i), "MessageId": f"m{i}"} for i in range(n)],
                "Failed": [],
            }

        self.mock_sqs.send_message_batch.side_effect = mock_batch
        response = self.client.post("/send/bulk", json={"count": 25})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(call_count, 3)  # 10 + 10 + 5

    def test_bulk_send_template_substitution(self):
        """Body template {index} should be replaced with message index."""
        captured_bodies = []

        def mock_batch(*args, **kwargs):
            for entry in kwargs.get("Entries", []):
                captured_bodies.append(entry["MessageBody"])
            n = len(kwargs["Entries"])
            return {
                "Successful": [{"Id": str(i), "MessageId": f"m{i}"} for i in range(n)],
                "Failed": [],
            }

        self.mock_sqs.send_message_batch.side_effect = mock_batch
        response = self.client.post("/send/bulk", json={
            "count": 3,
            "body_template": '{"id": {index}}',
        })
        self.assertEqual(response.status_code, 200)
        self.assertIn('{"id": 0}', captured_bodies)
        self.assertIn('{"id": 1}', captured_bodies)
        self.assertIn('{"id": 2}', captured_bodies)

    def test_bulk_send_count_above_500_rejected(self):
        """count > 500 should return 422 (Pydantic ge/le validation)."""
        response = self.client.post("/send/bulk", json={"count": 501})
        self.assertEqual(response.status_code, 422)

    def test_bulk_send_count_0_rejected(self):
        """count=0 should return 422."""
        response = self.client.post("/send/bulk", json={"count": 0})
        self.assertEqual(response.status_code, 422)

    def test_bulk_send_response_fields(self):
        """Response must include sent, failed, queue_type, total_duration_ms."""
        response = self.client.post("/send/bulk", json={"count": 1})
        data = response.json()
        for field in ["sent", "failed", "queue_type", "total_duration_ms"]:
            self.assertIn(field, data, f"Missing: {field}")


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestQueueDepthEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_sqs, self.api = _make_client()

    def test_queue_depth_returns_both_queues(self):
        """GET /queue/depth should return depth for both priority and batch queues."""
        self.mock_sqs.get_queue_attributes.return_value = {
            "Attributes": {"ApproximateNumberOfMessages": "7"}
        }
        response = self.client.get("/queue/depth")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        for field in ["priority_queue_depth", "batch_queue_depth", "total_depth"]:
            self.assertIn(field, data)

    def test_queue_depth_total_is_sum(self):
        """total_depth should equal priority + batch depths."""
        call_count = [0]

        def mock_attrs(*args, **kwargs):
            call_count[0] += 1
            # Return different depths for each call
            depth = 10 if call_count[0] == 1 else 5
            return {"Attributes": {"ApproximateNumberOfMessages": str(depth)}}

        self.mock_sqs.get_queue_attributes.side_effect = mock_attrs
        response = self.client.get("/queue/depth")
        data = response.json()
        self.assertEqual(data["total_depth"], 15)

    def test_queue_depth_queries_both_urls(self):
        """Should query both priority and batch queue URLs."""
        self.client.get("/queue/depth")
        call_urls = [
            c[1]["QueueUrl"] for c in self.mock_sqs.get_queue_attributes.call_args_list
        ]
        self.assertIn("https://sqs.test/priority", call_urls)
        self.assertIn("https://sqs.test/batch", call_urls)


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestMetricsEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_sqs, self.api = _make_client()

    def test_metrics_returns_producer_metrics(self):
        """GET /metrics should include producer_* metric names."""
        response = self.client.get("/metrics")
        self.assertEqual(response.status_code, 200)
        self.assertIn("producer_", response.text)


if __name__ == "__main__":
    unittest.main()
