"""
performance_test.py — Throughput and Latency Micro-Benchmarks
=============================================================
Measures the raw performance of process_message() in isolation
(no network, no SQS I/O — pure Python execution time).

Why micro-benchmarks separate from integration tests?
  Integration tests (load-test.sh): measure end-to-end including SQS, KEDA,
    pod scheduling — many variables, slow, requires a cluster.
  Micro-benchmarks (this file): measure ONLY the Python code path,
    pinpoint regressions in process_message() logic, run in CI in seconds.

If P99 from benchmark.sh is high → run these tests to isolate root cause:
  Scenario A: process_message() is fast (< 1ms) → bottleneck is SQS or network
  Scenario B: process_message() is slow (> 50ms) → bottleneck is Python code

Run:
    cd application
    pytest performance_test.py -v -s

    # With timing output
    pytest performance_test.py -v -s --tb=short

    # Run only throughput tests
    pytest performance_test.py -v -k "throughput"
"""

from __future__ import annotations

import json
import logging
import os
import time
from statistics import mean, quantiles, stdev
from unittest.mock import patch

import pytest

# Suppress logging noise during benchmarks
os.environ.setdefault("LOG_LEVEL", "WARNING")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")


# ─── Fixtures ─────────────────────────────────────────────────────────────────

@pytest.fixture
def logger():
    return logging.getLogger("perf-test")


@pytest.fixture
def sample_message():
    """A realistic SQS message payload (matches production format)."""
    return {
        "MessageId": "perf-msg-001",
        "ReceiptHandle": "rh-perf-001",
        "Body": json.dumps({
            "event": "order.created",
            "order_id": "ord-perf-9999",
            "customer_id": "cust-perf-001",
            "items": [{"sku": "SKU-A", "qty": 2, "price": 29.99}],
            "timestamp": "2026-09-13T17:00:00Z",
        }),
        "Attributes": {"ApproximateReceiveCount": "1"},
    }


@pytest.fixture
def large_message():
    """A large SQS message (256KB is SQS max) to test memory handling."""
    payload = {
        "event": "bulk.import",
        "records": [{"id": i, "data": "x" * 100} for i in range(1000)],
    }
    return {
        "MessageId": "perf-msg-large",
        "ReceiptHandle": "rh-perf-large",
        "Body": json.dumps(payload),
        "Attributes": {"ApproximateReceiveCount": "1"},
    }


def run_timed(fn, n: int) -> list[float]:
    """Run fn() n times and return a list of per-call durations in seconds."""
    durations = []
    for _ in range(n):
        t_start = time.perf_counter()
        fn()
        durations.append(time.perf_counter() - t_start)
    return durations


def summarize(label: str, durations: list[float]) -> dict:
    """Print and return summary statistics."""
    qs = quantiles(durations, n=100)  # percentiles
    p50 = qs[49] * 1000  # ms
    p95 = qs[94] * 1000
    p99 = qs[98] * 1000
    avg = mean(durations) * 1000
    sd = stdev(durations) * 1000 if len(durations) > 1 else 0.0
    throughput = len(durations) / sum(durations)

    print(f"\n  📊 {label}")
    print(f"     N={len(durations)}  avg={avg:.2f}ms  p50={p50:.2f}ms  "
          f"p95={p95:.2f}ms  p99={p99:.2f}ms  ±{sd:.2f}ms")
    print(f"     Throughput: {throughput:.1f} calls/sec")

    return {
        "label": label,
        "n": len(durations),
        "avg_ms": round(avg, 3),
        "p50_ms": round(p50, 3),
        "p95_ms": round(p95, 3),
        "p99_ms": round(p99, 3),
        "stddev_ms": round(sd, 3),
        "throughput_per_s": round(throughput, 1),
    }


# ─── Benchmark 1: Single Message Throughput ───────────────────────────────────

class TestSingleMessageThroughput:
    """
    Measures process_message() call overhead with a typical payload.
    Target: P99 < 50ms (most processing time should be I/O, not CPU).
    """

    N = 200  # Number of repetitions for statistically stable results

    def test_typical_payload_p99_under_50ms(self, sample_message, logger):
        """P99 processing latency for a typical order event must be < 50ms."""
        from app import process_message

        durations = run_timed(
            lambda: process_message(
                sample_message, logger,
                queue_url="https://sqs.us-east-1.amazonaws.com/123/test-queue"
            ),
            self.N,
        )
        stats = summarize("Typical Payload (order.created)", durations)

        assert stats["p99_ms"] < 50.0, (
            f"P99 latency {stats['p99_ms']:.1f}ms exceeds 50ms target. "
            f"Investigate: JSON parsing, logging overhead, metric recording."
        )

    def test_typical_payload_throughput_above_100_per_sec(self, sample_message, logger):
        """
        process_message() alone must support > 100 calls/sec.
        In production: each pod processes 1 message at a time, but this
        validates that Python code is not the bottleneck (SQS I/O should be).
        """
        from app import process_message

        durations = run_timed(
            lambda: process_message(
                sample_message, logger,
                queue_url="https://sqs.us-east-1.amazonaws.com/123/test-queue"
            ),
            self.N,
        )
        stats = summarize("Throughput Check", durations)

        assert stats["throughput_per_s"] > 100, (
            f"Throughput {stats['throughput_per_s']:.1f}/s is below 100/s. "
            f"Python code path is unexpectedly slow — profile with cProfile."
        )


# ─── Benchmark 2: Large Message Handling ──────────────────────────────────────

class TestLargeMessageHandling:
    """
    Validates that large payloads (many records) don't cause disproportionate
    processing time. Processing time should scale linearly with payload size,
    not exponentially.
    """

    N = 50

    def test_large_payload_processes_within_500ms(self, large_message, logger):
        """
        A 1,000-record payload must still process within 500ms.
        (SQS max message size is 256KB — we test with ~100KB equivalent)
        """
        from app import process_message

        durations = run_timed(
            lambda: process_message(
                large_message, logger,
                queue_url="https://sqs.us-east-1.amazonaws.com/123/test-queue"
            ),
            self.N,
        )
        stats = summarize("Large Payload (1000 records)", durations)

        assert stats["p99_ms"] < 500.0, (
            f"Large payload P99 {stats['p99_ms']:.1f}ms exceeds 500ms. "
            f"Check: JSON decode time, any O(n²) iteration in process_message()."
        )


# ─── Benchmark 3: Invalid Payload Overhead ────────────────────────────────────

class TestInvalidPayloadOverhead:
    """
    Invalid messages (bad JSON, missing fields) should be rejected quickly.
    A slow failure path can block the consumer while the DLQ fills up.
    """

    N = 200

    def test_invalid_json_rejected_fast(self, logger):
        """Bad JSON must be detected and returned False within 5ms."""
        from app import process_message

        bad_msg = {
            "MessageId": "bad-msg",
            "ReceiptHandle": "rh-bad",
            "Body": "NOT JSON {{{",
            "Attributes": {},
        }
        durations = run_timed(
            lambda: process_message(
                bad_msg, logger,
                queue_url="https://sqs.us-east-1.amazonaws.com/123/test-queue"
            ),
            self.N,
        )
        stats = summarize("Invalid JSON Rejection", durations)

        assert stats["p99_ms"] < 5.0, (
            f"Invalid JSON rejection P99 {stats['p99_ms']:.1f}ms > 5ms. "
            f"Error path should be fast — check for expensive logging on errors."
        )


# ─── Benchmark 4: Baseline Regression Guard ───────────────────────────────────

class TestBaselineRegressionGuard:
    """
    Stores a baseline P99 and fails if performance regresses by > 2x.
    Run manually after optimizations to update the baseline.
    """

    # Baseline P99 in milliseconds (update after each optimization sprint)
    BASELINE_P99_MS = 10.0
    REGRESSION_FACTOR = 2.0  # Fail if P99 > BASELINE * REGRESSION_FACTOR

    N = 100

    def test_no_regression_from_baseline(self, sample_message, logger):
        """
        P99 must not regress beyond 2x the established baseline.
        If this test fails: a recent change introduced a performance regression.
        Bisect: git bisect to find the commit that caused the regression.
        """
        from app import process_message

        durations = run_timed(
            lambda: process_message(
                sample_message, logger,
                queue_url="https://sqs.us-east-1.amazonaws.com/123/test-queue"
            ),
            self.N,
        )
        stats = summarize("Baseline Regression Guard", durations)

        threshold = self.BASELINE_P99_MS * self.REGRESSION_FACTOR
        assert stats["p99_ms"] < threshold, (
            f"PERFORMANCE REGRESSION DETECTED! "
            f"P99 {stats['p99_ms']:.1f}ms > {threshold:.1f}ms "
            f"(baseline {self.BASELINE_P99_MS}ms × regression factor {self.REGRESSION_FACTOR}x). "
            f"Run: git bisect to find the regression commit."
        )
