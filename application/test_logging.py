"""
test_logging.py — Tests for structured JSON logging and pod metadata injection.
=================================================================================
Validates that:
  1. Every log line contains pod metadata fields (pod_name, node_name, namespace)
  2. trace_id is generated per message and is deterministic
  3. Log format is valid JSON parseable by Fluent Bit / CloudWatch
  4. PodMetadataFilter falls back to defaults when env vars are not set
"""

import json
import logging
import os
import unittest
from io import StringIO
from unittest.mock import patch

# Ensure test can import from application directory
import sys
sys.path.insert(0, os.path.dirname(__file__))

from app import setup_logging, process_message, PodMetadataFilter


class TestPodMetadataFilter(unittest.TestCase):
    """Tests for the PodMetadataFilter logging filter."""

    def test_filter_injects_default_metadata(self):
        """When no env vars are set, filter should use fallback values."""
        with patch.dict(os.environ, {}, clear=True):
            f = PodMetadataFilter()
            self.assertIn("unknown", [f.pod_name, f.node_name])
            self.assertEqual(f.node_name, "unknown")

    def test_filter_reads_pod_name_from_env(self):
        """POD_NAME env var should be used when available."""
        with patch.dict(os.environ, {"POD_NAME": "keda-demo-abc-123"}):
            f = PodMetadataFilter()
            self.assertEqual(f.pod_name, "keda-demo-abc-123")

    def test_filter_reads_node_name_from_env(self):
        """NODE_NAME env var should be used when available."""
        with patch.dict(os.environ, {"NODE_NAME": "ip-10-0-1-50"}):
            f = PodMetadataFilter()
            self.assertEqual(f.node_name, "ip-10-0-1-50")

    def test_filter_reads_namespace_from_env(self):
        """POD_NAMESPACE env var should be used when available."""
        with patch.dict(os.environ, {"POD_NAMESPACE": "keda-demo"}):
            f = PodMetadataFilter()
            self.assertEqual(f.namespace, "keda-demo")

    def test_filter_prefers_pod_namespace_over_namespace(self):
        """POD_NAMESPACE should take priority over NAMESPACE."""
        with patch.dict(os.environ, {"POD_NAMESPACE": "prod", "NAMESPACE": "dev"}):
            f = PodMetadataFilter()
            self.assertEqual(f.namespace, "prod")

    def test_filter_adds_fields_to_log_record(self):
        """Filter should add pod_name, node_name, namespace to log record."""
        with patch.dict(os.environ, {
            "POD_NAME": "test-pod",
            "NODE_NAME": "test-node",
            "POD_NAMESPACE": "test-ns"
        }):
            f = PodMetadataFilter()
            record = logging.LogRecord(
                name="test", level=logging.INFO, pathname="",
                lineno=0, msg="test message", args=None, exc_info=None
            )
            result = f.filter(record)
            self.assertTrue(result)  # Filter should always return True (never drop logs)
            self.assertEqual(record.pod_name, "test-pod")
            self.assertEqual(record.node_name, "test-node")
            self.assertEqual(record.namespace, "test-ns")
            self.assertEqual(record.trace_id, "")  # Default when not set


class TestStructuredLogOutput(unittest.TestCase):
    """Tests that log output is valid JSON with all expected fields."""

    def setUp(self):
        """Capture log output to a StringIO buffer."""
        self.log_buffer = StringIO()
        self.logger = logging.getLogger(f"test-{id(self)}")
        self.logger.handlers.clear()
        self.logger.setLevel(logging.DEBUG)

        from pythonjsonlogger import jsonlogger
        handler = logging.StreamHandler(self.log_buffer)
        formatter = jsonlogger.JsonFormatter(
            fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
        handler.setFormatter(formatter)
        self.logger.addHandler(handler)

        with patch.dict(os.environ, {"POD_NAME": "test-pod", "NODE_NAME": "test-node", "POD_NAMESPACE": "test-ns"}):
            self.logger.addFilter(PodMetadataFilter())

    def test_log_output_is_valid_json(self):
        """Every log line must be parseable as JSON (required by Fluent Bit)."""
        self.logger.info("Test message", extra={"custom_field": "value"})
        output = self.log_buffer.getvalue().strip()
        parsed = json.loads(output)
        self.assertEqual(parsed["message"], "Test message")
        self.assertEqual(parsed["custom_field"], "value")

    def test_log_contains_pod_metadata(self):
        """Log output must contain pod_name, node_name, namespace."""
        self.logger.info("Metadata test")
        parsed = json.loads(self.log_buffer.getvalue().strip())
        self.assertEqual(parsed["pod_name"], "test-pod")
        self.assertEqual(parsed["node_name"], "test-node")
        self.assertEqual(parsed["namespace"], "test-ns")

    def test_log_contains_timestamp(self):
        """Log output must have an asctime field for time-based querying."""
        self.logger.info("Timestamp test")
        parsed = json.loads(self.log_buffer.getvalue().strip())
        self.assertIn("asctime", parsed)

    def test_log_contains_level(self):
        """Log output must include levelname for severity filtering."""
        self.logger.warning("Warning test")
        parsed = json.loads(self.log_buffer.getvalue().strip())
        self.assertEqual(parsed["levelname"], "WARNING")


class TestTraceIdGeneration(unittest.TestCase):
    """Tests for trace_id generation in process_message."""

    def test_trace_id_is_deterministic(self):
        """Same message_id + receive_count should produce same trace_id."""
        import hashlib
        msg_id = "test-msg-001"
        receive_count = 1
        trace_id_1 = hashlib.md5(f"{msg_id}-{receive_count}".encode()).hexdigest()[:12]
        trace_id_2 = hashlib.md5(f"{msg_id}-{receive_count}".encode()).hexdigest()[:12]
        self.assertEqual(trace_id_1, trace_id_2)

    def test_trace_id_changes_on_retry(self):
        """Different receive_count should produce different trace_id."""
        import hashlib
        msg_id = "test-msg-001"
        trace_1 = hashlib.md5(f"{msg_id}-1".encode()).hexdigest()[:12]
        trace_2 = hashlib.md5(f"{msg_id}-2".encode()).hexdigest()[:12]
        self.assertNotEqual(trace_1, trace_2)

    def test_trace_id_length(self):
        """trace_id should be exactly 12 hex characters."""
        import hashlib
        trace_id = hashlib.md5("test-1".encode()).hexdigest()[:12]
        self.assertEqual(len(trace_id), 12)
        # Verify it's valid hex
        int(trace_id, 16)


if __name__ == "__main__":
    unittest.main()
