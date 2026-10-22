"""
ai/test_predictor.py — Unit tests for the QueueDepthPredictor
==============================================================
Run: pytest ai/test_predictor.py -v
"""
from __future__ import annotations

import math
import time

import pytest

from predictor import (
    ObservationInput,
    PredictorConfig,
    QueueDepthPredictor,
    build_features,
    features_to_vector,
)


class TestBuildFeatures:
    def test_returns_current_depth_for_single_obs(self):
        feats = build_features([10])
        assert feats["current_depth"] == 10.0

    def test_delta_1_is_difference_from_previous(self):
        feats = build_features([5, 10])
        assert feats["delta_1"] == pytest.approx(5.0)

    def test_rolling_mean_over_window(self):
        feats = build_features([2, 4, 6, 8, 10], window=5)
        assert feats["rolling_mean"] == pytest.approx(6.0)

    def test_no_negative_rolling_std(self):
        feats = build_features([5, 5, 5, 5])
        assert feats["rolling_std"] >= 0.0


class TestPredictorReadiness:
    def test_not_ready_initially(self):
        p = QueueDepthPredictor(PredictorConfig(min_observations=10))
        assert not p.is_ready()

    def test_ready_after_min_observations(self):
        p = QueueDepthPredictor(PredictorConfig(min_observations=10))
        for i in range(25):  # need enough for training samples too
            p.record_observation(depth=i * 2, timestamp=float(i * 15))
        assert p.is_ready()

    def test_predict_returns_none_when_not_ready(self):
        p = QueueDepthPredictor(PredictorConfig(min_observations=10))
        p.record_observation(depth=5)
        assert p.predict() is None


class TestPredictorOutput:
    def _make_ready_predictor(self, depths: list) -> QueueDepthPredictor:
        cfg = PredictorConfig(min_observations=10, observation_interval_s=15)
        p = QueueDepthPredictor(cfg)
        for i, d in enumerate(depths):
            p.record_observation(depth=d, timestamp=float(i * 15))
        return p

    def test_prediction_not_negative(self):
        depths = [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        p = self._make_ready_predictor(depths)
        result = p.predict()
        if result:
            assert result.predicted_depth >= 0.0

    def test_recommended_replicas_within_bounds(self):
        depths = list(range(30))  # 0..29
        p = self._make_ready_predictor(depths)
        result = p.predict()
        if result:
            assert 0 <= result.recommended_replicas <= p.config.max_replicas

    def test_depth_to_replicas_formula_matches_keda(self):
        cfg = PredictorConfig(target_queue_length=5, max_replicas=5)
        p = QueueDepthPredictor(cfg)
        assert p._depth_to_replicas(0) == 0
        assert p._depth_to_replicas(1) == 1
        assert p._depth_to_replicas(5) == 1
        assert p._depth_to_replicas(6) == 2
        assert p._depth_to_replicas(25) == 5
        assert p._depth_to_replicas(100) == 5  # capped at max_replicas

    def test_confidence_between_0_and_1(self):
        depths = list(range(30))
        p = self._make_ready_predictor(depths)
        result = p.predict()
        if result:
            assert 0.0 <= result.confidence <= 1.0

    def test_summary_has_expected_keys(self):
        p = QueueDepthPredictor()
        summary = p.summary()
        for key in ["observations", "model_trained", "is_ready", "predictions_made"]:
            assert key in summary
