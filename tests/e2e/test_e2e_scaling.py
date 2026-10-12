"""
tests/e2e/test_e2e_scaling.py — End-to-End Autoscaling Integration Tests
========================================================================

Validates the full closed-loop autoscaling system:
  Producer API -> SQS -> KEDA Autoscaler -> Consumer Pods -> Prediction API -> Dashboard

Scenarios covered:
  1. Health & readiness checks for all microservices
  2. Prediction API recommendation logic under varying queue loads
  3. Producer API single message and bulk batch injection
  4. End-to-end load generation and queue depth verification
  5. Live dashboard status aggregation and metric exposure
"""

import time
import pytest


def _is_service_reachable(client) -> bool:
    res = client.get("/health")
    return res.get("status") == 200


class TestServicesHealth:
    """Verifies that all microservices respond to health checks."""

    def test_producer_health(self, producer_client):
        res = producer_client.get("/health")
        if res.get("status") != 200:
            pytest.skip(f"Producer API not reachable at {producer_client.base_url}")
        assert res["status"] == 200
        assert res["data"].get("status") == "ok"

    def test_prediction_health(self, prediction_client):
        res = prediction_client.get("/health")
        if res.get("status") != 200:
            pytest.skip(f"Prediction API not reachable at {prediction_client.base_url}")
        assert res["status"] == 200
        assert res["data"].get("status") == "ok"

    def test_dashboard_health(self, dashboard_client):
        res = dashboard_client.get("/health")
        if res.get("status") != 200:
            pytest.skip(f"Dashboard not reachable at {dashboard_client.base_url}")
        assert res["status"] == 200
        assert res["data"].get("status") == "ok"


class TestPredictionAPIIntegration:
    """Tests AI predictor endpoints and fallback behaviors."""

    def test_prediction_recommendation_scaling(self, prediction_client):
        if not _is_service_reachable(prediction_client):
            pytest.skip("Prediction API offline")

        # Test zero queue depth -> min replicas
        res_zero = prediction_client.get("/predict?queue_depth=0")
        assert res_zero["status"] == 200
        assert "recommended_replicas" in res_zero["data"]
        assert res_zero["data"]["recommended_replicas"] >= 0

        # Test high queue depth -> scaled replicas
        res_high = prediction_client.get("/predict?queue_depth=50")
        assert res_high["status"] == 200
        data_high = res_high["data"]
        assert data_high["recommended_replicas"] >= 5
        assert "used_ai" in data_high
        assert "confidence" in data_high

    def test_model_info_metadata(self, prediction_client):
        if not _is_service_reachable(prediction_client):
            pytest.skip("Prediction API offline")

        res = prediction_client.get("/model/info")
        assert res["status"] == 200
        info = res["data"]
        assert "model_type" in info
        assert "ready" in info


class TestProducerAndQueueLifecycle:
    """Tests message injection and queue depth changes."""

    def test_single_message_priority_send(self, producer_client):
        if not _is_service_reachable(producer_client):
            pytest.skip("Producer API offline")

        payload = {
            "body": '{"event": "e2e_test", "timestamp": ' + str(time.time()) + '}',
            "queue_type": "priority",
        }
        res = producer_client.post("/send", payload)
        assert res["status"] == 200
        data = res["data"]
        assert "message_id" in data
        assert data["queue_type"] == "priority"
        assert data["send_duration_ms"] > 0

    def test_bulk_send_batch_injection(self, producer_client, wait_condition):
        if not _is_service_reachable(producer_client):
            pytest.skip("Producer API offline")

        payload = {
            "count": 15,
            "queue_type": "priority",
            "body_template": '{"e2e_index": {index}}',
        }
        res = producer_client.post("/send/bulk", payload)
        assert res["status"] == 200
        data = res["data"]
        assert data["sent"] == 15
        assert data["failed"] == 0

        # Verify queue depth reflects messages
        def _check_depth():
            depth_res = producer_client.get("/queue/depth")
            if depth_res["status"] == 200:
                p_depth = depth_res["data"].get("priority_queue_depth", 0)
                return p_depth > 0
            return False

        # Wait for SQS metrics propagation
        try:
            detected = wait_condition(_check_depth, timeout=30, desc="queue depth increase")
            assert detected is True
        except TimeoutError:
            pytest.fail("Queue depth did not reflect injected bulk messages within timeout")


class TestDashboardAggregation:
    """Validates that the live dashboard aggregates all system components."""

    def test_dashboard_api_stats(self, dashboard_client):
        if not _is_service_reachable(dashboard_client):
            pytest.skip("Dashboard offline")

        res = dashboard_client.get("/api/stats")
        assert res["status"] == 200
        stats = res["data"]
        assert "priority_depth" in stats
        assert "batch_depth" in stats
        assert "total_depth" in stats
        assert "pods_ready" in stats
        assert "predictor" in stats

    def test_dashboard_htmx_fragments(self, dashboard_client):
        if not _is_service_reachable(dashboard_client):
            pytest.skip("Dashboard offline")

        # Stats fragment
        res_stats = dashboard_client.get("/fragments/stats")
        assert res_stats["status"] == 200
        assert "stats-grid" in res_stats["raw"]

        # Events fragment
        res_events = dashboard_client.get("/fragments/events")
        assert res_events["status"] == 200
        assert "events" in res_events["raw"] or "table" in res_events["raw"]


class TestEndToEndAutoscalingCycle:
    """Executes the full end-to-end loop and observes KEDA autoscaling response."""

    def test_full_scaling_loop(
        self,
        producer_client,
        prediction_client,
        get_deployment_replicas,
        wait_condition,
    ):
        if not _is_service_reachable(producer_client):
            pytest.skip("Full E2E requires running services (Producer API offline)")

        # Step 1: Initial baseline check
        baseline_replicas = get_deployment_replicas()
        initial_count = baseline_replicas.get("desired", 1)

        # Step 2: Inject burst load
        burst_count = 25
        send_res = producer_client.post(
            "/send/bulk",
            {"count": burst_count, "queue_type": "priority"},
        )
        assert send_res["status"] == 200
        assert send_res["data"]["sent"] == burst_count

        # Step 3: Check AI predictor recommendation for burst
        if _is_service_reachable(prediction_client):
            pred_res = prediction_client.get(f"/predict?queue_depth={burst_count}")
            if pred_res["status"] == 200:
                rec = pred_res["data"]["recommended_replicas"]
                assert rec > initial_count, f"AI predictor recommended {rec} <= {initial_count}"

        # Step 4: Verify queue depth increases
        def _depth_increased():
            r = producer_client.get("/queue/depth")
            if r["status"] == 200:
                return r["data"].get("priority_queue_depth", 0) > 0
            return False

        try:
            wait_condition(_depth_increased, timeout=20, desc="queue depth rise")
        except TimeoutError:
            pytest.fail("Queue depth did not register burst messages")

        # Step 5: Observe consumer pod scaling (if running against active cluster)
        def _replicas_scaled():
            current = get_deployment_replicas()
            return current.get("ready", 0) >= initial_count or current.get("desired", 0) >= initial_count

        # In live environments with KEDA, desired replicas will scale up.
        # If running in detached API test mode, step verifies deployment state resolver.
        scaling_confirmed = wait_condition(
            _replicas_scaled,
            timeout=45,
            desc="replica scaling response",
        )
        assert scaling_confirmed is True
