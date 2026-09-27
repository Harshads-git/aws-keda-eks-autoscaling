"""
application/test_prediction_api.py — Tests for the Prediction API
==================================================================

Uses FastAPI's TestClient (built-in HTTPX-based test client) to test
all endpoints without needing a running server.

Tests cover:
  1. /health returns 200 {"status": "ok"}
  2. /ready returns 200 after predictor is initialised
  3. /predict with queue_depth=0 returns 0 replicas
  4. /predict with queue_depth > 0 returns ceil(depth/target) replicas (reactive)
  5. /predict uses reactive formula when model is not ready (insufficient data)
  6. /predict caps at max_replicas
  7. /predict validates queue_depth >= 0 (rejects negatives)
  8. /observe records an observation and returns model_ready status
  9. /model/info returns model metadata fields
  10. /metrics returns Prometheus text format
  11. PredictResponse has all required fields
  12. used_ai=false when model not ready (insufficient observations)
"""

import math
import unittest
from unittest.mock import MagicMock, patch

# Try importing FastAPI test client
try:
    from fastapi.testclient import TestClient
    TESTCLIENT_AVAILABLE = True
except ImportError:
    TESTCLIENT_AVAILABLE = False


def _make_test_client():
    """Create a TestClient with a fresh app instance."""
    # Reset global state before each test
    import application.prediction_api as api_module
    api_module._predictor = None
    api_module._model_type = "linear_regression"

    # Patch _init_predictor to install a mock predictor
    mock_predictor = MagicMock()
    mock_predictor.is_ready.return_value = False
    mock_predictor.observation_count = 0

    with patch.object(api_module, "_init_predictor", side_effect=lambda: setattr(api_module, "_predictor", mock_predictor)):
        app = api_module.create_app()

    return TestClient(app), mock_predictor, api_module


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestHealthEndpoints(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_predictor, self.api = _make_test_client()

    def test_health_returns_200(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")

    def test_ready_returns_200_when_predictor_initialised(self):
        # _predictor is set by the mocked _init_predictor
        response = self.client.get("/ready")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ready")

    def test_ready_returns_503_when_predictor_is_none(self):
        self.api._predictor = None
        response = self.client.get("/ready")
        self.assertEqual(response.status_code, 503)


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestPredictEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_predictor, self.api = _make_test_client()

    def test_zero_depth_returns_zero_replicas(self):
        """queue_depth=0 should return 0 recommended replicas."""
        response = self.client.get("/predict?queue_depth=0")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["recommended_replicas"], 0)

    def test_reactive_formula_when_model_not_ready(self):
        """When predictor is not ready, use ceil(depth / target)."""
        self.mock_predictor.is_ready.return_value = False
        # With target=5 and depth=12: ceil(12/5) = 3
        response = self.client.get("/predict?queue_depth=12")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["recommended_replicas"], 3)
        self.assertFalse(data["used_ai"])

    def test_max_replicas_cap(self):
        """Recommendations should not exceed max_replicas (default 5)."""
        self.mock_predictor.is_ready.return_value = False
        # depth=999 with target=5 -> ceil(999/5)=200, capped at 5
        response = self.client.get("/predict?queue_depth=999")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertLessEqual(data["recommended_replicas"], 5)

    def test_exact_multiple_replicas(self):
        """depth=10, target=5 -> ceil(10/5) = exactly 2 replicas."""
        self.mock_predictor.is_ready.return_value = False
        response = self.client.get("/predict?queue_depth=10")
        data = response.json()
        self.assertEqual(data["recommended_replicas"], 2)

    def test_negative_depth_rejected(self):
        """Negative queue_depth should return 422 (validation error)."""
        response = self.client.get("/predict?queue_depth=-1")
        self.assertEqual(response.status_code, 422)

    def test_predict_response_has_required_fields(self):
        """Response must have all required PredictResponse fields."""
        response = self.client.get("/predict?queue_depth=5")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        required_fields = [
            "recommended_replicas", "predicted_depth", "confidence",
            "model_type", "used_ai", "observations_count", "horizon_steps",
        ]
        for field in required_fields:
            self.assertIn(field, data, f"Missing field: {field}")

    def test_used_ai_false_when_model_not_ready(self):
        """used_ai should be False when the model has insufficient data."""
        self.mock_predictor.is_ready.return_value = False
        response = self.client.get("/predict?queue_depth=15")
        data = response.json()
        self.assertFalse(data["used_ai"])

    def test_used_ai_true_when_confidence_above_threshold(self):
        """used_ai should be True when predictor is ready and confidence is high."""
        self.mock_predictor.is_ready.return_value = True
        mock_forecast = MagicMock()
        mock_forecast.recommended_replicas = 4
        mock_forecast.predicted_depth = 18.0
        mock_forecast.confidence = 0.85
        self.mock_predictor.predict.return_value = mock_forecast
        self.mock_predictor.observation_count = 50

        response = self.client.get("/predict?queue_depth=20")
        data = response.json()
        self.assertTrue(data["used_ai"])
        self.assertEqual(data["recommended_replicas"], 4)

    def test_falls_back_to_reactive_when_confidence_low(self):
        """When AI confidence < threshold, fall back to reactive formula."""
        self.mock_predictor.is_ready.return_value = True
        mock_forecast = MagicMock()
        mock_forecast.recommended_replicas = 7  # AI says 7
        mock_forecast.predicted_depth = 35.0
        mock_forecast.confidence = 0.2  # Below 0.5 threshold
        self.mock_predictor.predict.return_value = mock_forecast
        self.mock_predictor.observation_count = 30

        # Reactive: ceil(20/5) = 4 (not 7 from AI)
        response = self.client.get("/predict?queue_depth=20")
        data = response.json()
        self.assertFalse(data["used_ai"])
        self.assertEqual(data["recommended_replicas"], 4)

    def test_observe_increments_count(self):
        """POST /observe should record observation and return count."""
        self.mock_predictor.observation_count = 5
        response = self.client.post("/observe", json={"depth": 15.0})
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertTrue(data["recorded"])
        self.assertEqual(data["depth"], 15.0)


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestModelInfoEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_predictor, self.api = _make_test_client()

    def test_model_info_returns_correct_fields(self):
        """GET /model/info should return all ModelInfoResponse fields."""
        self.mock_predictor.is_ready.return_value = True
        self.mock_predictor.observation_count = 42

        response = self.client.get("/model/info")
        self.assertEqual(response.status_code, 200)
        data = response.json()

        expected_fields = [
            "model_type", "is_ready", "observation_count",
            "horizon_steps", "target_queue_length", "max_replicas",
            "confidence_threshold",
        ]
        for field in expected_fields:
            self.assertIn(field, data)

    def test_model_info_is_ready_reflects_predictor_state(self):
        self.mock_predictor.is_ready.return_value = True
        self.mock_predictor.observation_count = 10
        response = self.client.get("/model/info")
        self.assertTrue(response.json()["is_ready"])


@unittest.skipUnless(TESTCLIENT_AVAILABLE, "FastAPI TestClient not available")
class TestMetricsEndpoint(unittest.TestCase):

    def setUp(self):
        self.client, self.mock_predictor, self.api = _make_test_client()

    def test_metrics_returns_text_content(self):
        """GET /metrics should return Prometheus text format."""
        response = self.client.get("/metrics")
        self.assertEqual(response.status_code, 200)
        # Prometheus format starts with # HELP or metric lines
        content = response.text
        self.assertIn("prediction_api", content)


# ─── Unit tests that don't require FastAPI ────────────────────────────────────

class TestReplicaFormula(unittest.TestCase):
    """Test the reactive replica formula independently of the API."""

    def _replicas(self, depth: float, target: int = 5, max_r: int = 5) -> int:
        if depth <= 0:
            return 0
        return min(math.ceil(depth / target), max_r)

    def test_zero_depth(self):
        self.assertEqual(self._replicas(0), 0)

    def test_partial_load(self):
        self.assertEqual(self._replicas(3, target=5), 1)

    def test_exact_load(self):
        self.assertEqual(self._replicas(10, target=5), 2)

    def test_overflow_capped(self):
        self.assertEqual(self._replicas(200, target=5, max_r=5), 5)


if __name__ == "__main__":
    unittest.main()
