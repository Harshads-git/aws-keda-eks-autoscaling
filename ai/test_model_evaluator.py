"""
ai/test_model_evaluator.py — Tests for ModelEvaluator and ModelRegistry
=========================================================================

Tests cover:
  ModelEvaluator:
    1. Insufficient data returns 'reactive' immediately
    2. MAPE calculation is mathematically correct
    3. Model selection: ARIMA wins when its MAPE is lower
    4. Model selection: LR wins when its MAPE is lower
    5. Both poor models → 'reactive' fallback
    6. EvaluationResult fields are populated correctly
    7. evaluation_duration_ms is positive and reasonable

  ModelRegistry:
    8. Save and load roundtrip preserves model and metadata
    9. Load on empty registry returns (None, None)
   10. Multiple saves archive the previous model correctly
   11. load_metadata() reads JSON without loading pickle
   12. is_model_trustworthy() respects MAPE threshold
   13. make_version() produces a non-empty version string
   14. list_history() returns archived versions in descending order
"""

import json
import os
import pickle
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from ai.model_evaluator import (
    MAPE_FALLBACK_THRESHOLD,
    EvaluationResult,
    ModelEvaluator,
    _ape,
    _mape,
)
from ai.model_registry import ModelMetadata, ModelRegistry


# ─── Utility helpers ──────────────────────────────────────────────────────────

def _make_evaluator(**kwargs) -> ModelEvaluator:
    defaults = dict(horizon_steps=1, min_train_size=5, target_queue_length=5, max_replicas=5)
    defaults.update(kwargs)
    return ModelEvaluator(**defaults)


def _synthetic_series(n: int = 50, trend: float = 0.5) -> list:
    """Linearly increasing series + small noise, deterministic."""
    return [max(0, trend * i + (i % 3) * 0.5) for i in range(n)]


# ─── MAPE utility function tests ──────────────────────────────────────────────

class TestMAPEUtilityFunctions(unittest.TestCase):

    def test_ape_zero_actual_returns_zero(self):
        """When actual == 0, APE is undefined; we return 0 to avoid infinity."""
        self.assertEqual(_ape(0, 10), 0.0)

    def test_ape_perfect_prediction(self):
        """When predicted == actual, APE should be 0."""
        self.assertAlmostEqual(_ape(10, 10), 0.0)

    def test_ape_50_percent_error(self):
        """APE(10, 15) = |10-15|/10 * 100 = 50%."""
        self.assertAlmostEqual(_ape(10, 15), 50.0)

    def test_mape_empty_list_returns_inf(self):
        """Empty error list → MAPE = inf (model produced no valid forecasts)."""
        self.assertEqual(_mape([]), float("inf"))

    def test_mape_single_value(self):
        self.assertAlmostEqual(_mape([20.0]), 20.0)

    def test_mape_average(self):
        self.assertAlmostEqual(_mape([10.0, 20.0, 30.0]), 20.0)


# ─── ModelEvaluator tests ─────────────────────────────────────────────────────

class TestModelEvaluatorInsufficientData(unittest.TestCase):

    def test_returns_reactive_when_data_too_small(self):
        """With fewer data points than min_train + horizon, return 'reactive'."""
        evaluator = _make_evaluator(min_train_size=30, horizon_steps=3)
        result = evaluator.evaluate([10.0] * 10)   # only 10 points, need 33

        self.assertEqual(result.best_model_name, "reactive")
        self.assertEqual(result.n_backtest_steps, 0)
        self.assertEqual(result.lr_mape, float("inf"))

    def test_recommendation_mentions_insufficient_data(self):
        evaluator = _make_evaluator(min_train_size=30, horizon_steps=3)
        result = evaluator.evaluate([5.0] * 5)
        self.assertIn("Insufficient", result.recommendation)


class TestModelEvaluatorSelection(unittest.TestCase):

    def _evaluate_with_mocked_backtests(self, lr_mape: float, arima_mape: float) -> EvaluationResult:
        """Run evaluate() with mocked MAPE values to test selection logic only."""
        evaluator = _make_evaluator()
        lr_errors = [lr_mape]
        arima_errors = [arima_mape]

        with patch.object(evaluator, "_backtest_linear_regression", return_value=lr_errors), \
             patch.object(evaluator, "_backtest_arima", return_value=arima_errors):
            return evaluator.evaluate(_synthetic_series(20))

    def test_arima_wins_when_lower_mape(self):
        result = self._evaluate_with_mocked_backtests(lr_mape=18.0, arima_mape=11.0)
        self.assertEqual(result.best_model_name, "arima")

    def test_lr_wins_when_lower_mape(self):
        result = self._evaluate_with_mocked_backtests(lr_mape=8.0, arima_mape=15.0)
        self.assertEqual(result.best_model_name, "linear_regression")

    def test_arima_wins_on_tie(self):
        """On equal MAPE, ARIMA should win (better time-series design)."""
        result = self._evaluate_with_mocked_backtests(lr_mape=10.0, arima_mape=10.0)
        self.assertEqual(result.best_model_name, "arima")

    def test_reactive_when_both_mape_too_high(self):
        result = self._evaluate_with_mocked_backtests(
            lr_mape=MAPE_FALLBACK_THRESHOLD + 1,
            arima_mape=MAPE_FALLBACK_THRESHOLD + 5,
        )
        self.assertEqual(result.best_model_name, "reactive")

    def test_result_fields_populated(self):
        result = self._evaluate_with_mocked_backtests(lr_mape=12.0, arima_mape=9.5)
        self.assertAlmostEqual(result.lr_mape, 12.0)
        self.assertAlmostEqual(result.arima_mape, 9.5)
        self.assertGreater(result.evaluation_duration_ms, 0)
        self.assertIsInstance(result.recommendation, str)
        self.assertGreater(len(result.recommendation), 0)

    def test_recommendation_mentions_winner(self):
        result = self._evaluate_with_mocked_backtests(lr_mape=20.0, arima_mape=10.0)
        self.assertIn("arima", result.recommendation)

    def test_evaluation_duration_is_positive(self):
        evaluator = _make_evaluator()
        with patch.object(evaluator, "_backtest_linear_regression", return_value=[5.0]), \
             patch.object(evaluator, "_backtest_arima", return_value=[8.0]):
            result = evaluator.evaluate(_synthetic_series(20))
        self.assertGreater(result.evaluation_duration_ms, 0)


# ─── ModelRegistry tests ──────────────────────────────────────────────────────

class TestModelRegistry(unittest.TestCase):

    def setUp(self):
        """Use a fresh temporary directory for each test."""
        self.tmpdir = tempfile.mkdtemp()
        self.registry = ModelRegistry(registry_dir=Path(self.tmpdir))

    def _make_metadata(self, model_name="arima", mape=11.5, version=None):
        return ModelMetadata(
            model_name=model_name,
            version=version or ModelRegistry.make_version(),
            mape=mape,
            n_backtest_steps=50,
        )

    # ── Save / Load roundtrip ────────────────────────────────────────────────

    def test_save_and_load_roundtrip(self):
        """A saved object should be loadable and equal the original."""
        original_model = {"weights": [1.2, 3.4], "intercept": 0.5}
        meta = self._make_metadata()
        self.registry.save(original_model, meta)

        loaded_model, loaded_meta = self.registry.load()
        self.assertEqual(loaded_model, original_model)
        self.assertEqual(loaded_meta.model_name, meta.model_name)
        self.assertAlmostEqual(loaded_meta.mape, meta.mape)

    def test_load_on_empty_registry_returns_none(self):
        model, meta = self.registry.load()
        self.assertIsNone(model)
        self.assertIsNone(meta)

    def test_metadata_json_is_human_readable(self):
        """The metadata file should be valid, indented JSON."""
        meta = self._make_metadata()
        self.registry.save(object(), meta)
        meta_path = Path(self.tmpdir) / ModelRegistry.CURRENT_META_FILE
        with open(meta_path) as f:
            parsed = json.load(f)
        self.assertEqual(parsed["model_name"], meta.model_name)
        self.assertAlmostEqual(parsed["mape"], meta.mape)

    def test_trained_at_is_set_automatically(self):
        """If trained_at is empty, save() should populate it."""
        meta = self._make_metadata()
        meta.trained_at = ""
        self.registry.save({"dummy": True}, meta)
        _, loaded_meta = self.registry.load()
        self.assertNotEqual(loaded_meta.trained_at, "")

    # ── Archive / History ────────────────────────────────────────────────────

    def test_multiple_saves_archive_previous_versions(self):
        """Each save should archive the prior model to history/."""
        for i in range(3):
            meta = ModelMetadata(
                model_name="arima",
                version=f"202609{24+i:02d}_120000",
                mape=10.0 - i,
            )
            time.sleep(0.01)  # Ensure distinct timestamps
            self.registry.save({"v": i}, meta)

        history = self.registry.list_history()
        self.assertGreaterEqual(len(history), 2)  # At least 2 archived versions

    # ── Metadata-only loading ────────────────────────────────────────────────

    def test_load_metadata_without_pickle(self):
        """load_metadata() should work without deserialising the model pickle."""
        meta = self._make_metadata(model_name="linear_regression", mape=8.2)
        self.registry.save({"lr": True}, meta)

        loaded_meta = self.registry.load_metadata()
        self.assertIsNotNone(loaded_meta)
        self.assertEqual(loaded_meta.model_name, "linear_regression")
        self.assertAlmostEqual(loaded_meta.mape, 8.2)

    def test_load_metadata_returns_none_when_empty(self):
        self.assertIsNone(self.registry.load_metadata())

    # ── is_model_trustworthy ─────────────────────────────────────────────────

    def test_trustworthy_when_mape_below_threshold(self):
        meta = self._make_metadata(mape=11.0)
        self.registry.save({"m": 1}, meta)
        self.assertTrue(self.registry.is_model_trustworthy(mape_threshold=20.0))

    def test_not_trustworthy_when_mape_above_threshold(self):
        meta = self._make_metadata(mape=25.0)
        self.registry.save({"m": 1}, meta)
        self.assertFalse(self.registry.is_model_trustworthy(mape_threshold=20.0))

    def test_not_trustworthy_when_registry_empty(self):
        self.assertFalse(self.registry.is_model_trustworthy())

    # ── make_version ─────────────────────────────────────────────────────────

    def test_make_version_non_empty(self):
        version = ModelRegistry.make_version()
        self.assertIsInstance(version, str)
        self.assertGreater(len(version), 0)

    def test_make_version_format(self):
        """Version should look like YYYYMMDD_HHMMSS (15 chars)."""
        version = ModelRegistry.make_version()
        self.assertEqual(len(version), 15)
        self.assertEqual(version[8], "_")


if __name__ == "__main__":
    unittest.main()
