"""
ai/model_evaluator.py — Backtesting Framework & Automatic Model Selection
==========================================================================

Compares the Linear Regression predictor (ai/predictor.py) and the ARIMA
predictor (ai/arima_predictor.py) on held-out historical data using
walk-forward backtesting. Automatically selects the model with the lowest
Mean Absolute Percentage Error (MAPE).

How Walk-Forward Backtesting Works:
  Unlike a simple train/test split, walk-forward (also called "time-series
  cross-validation") simulates real deployment: at each step t, the model
  trains only on data before t and forecasts at t. This prevents look-ahead
  bias (the model cannot "see the future" during training).

  Example with 100 observations, horizon=3, min_train=30:
    Step 30: train on [0..29], forecast step 33, record error
    Step 31: train on [0..30], forecast step 34, record error
    ...
    Step 97: train on [0..96], forecast step 100, record error
  Result: 67 forecast errors → compute MAPE across all of them.

Usage:
    from ai.model_evaluator import ModelEvaluator

    evaluator = ModelEvaluator()
    result = evaluator.evaluate(historical_depths=[10, 12, 8, 15, ...])
    print(result.best_model_name)   # "arima" or "linear_regression"
    print(result.lr_mape)           # e.g. 18.3
    print(result.arima_mape)        # e.g. 11.7
    print(result.recommendation)    # "arima (MAPE 11.7% vs 18.3%)"
"""

import logging
import math
import pickle
import time
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

logger = logging.getLogger("keda-demo")

# MAPE threshold above which we consider a model unreliable and prefer
# falling back to reactive KEDA scaling.
MAPE_FALLBACK_THRESHOLD = 20.0


@dataclass
class EvaluationResult:
    """
    Results from a backtesting run comparing two models.

    Returned by ModelEvaluator.evaluate().
    """
    best_model_name: str
    """Either 'linear_regression', 'arima', or 'reactive' (if both MAPE > threshold)."""

    lr_mape: float
    """Mean Absolute Percentage Error for Linear Regression (lower = better)."""

    arima_mape: float
    """Mean Absolute Percentage Error for ARIMA (lower = better)."""

    lr_backtest_errors: List[float] = field(default_factory=list)
    """Per-step absolute percentage errors for Linear Regression."""

    arima_backtest_errors: List[float] = field(default_factory=list)
    """Per-step absolute percentage errors for ARIMA."""

    n_backtest_steps: int = 0
    """Number of walk-forward steps evaluated."""

    horizon_steps: int = 3
    """Forecast horizon used during backtesting."""

    evaluation_duration_ms: float = 0.0
    """Wall-clock time for the full evaluation run (milliseconds)."""

    recommendation: str = ""
    """Human-readable explanation of the selection decision."""


class ModelEvaluator:
    """
    Walk-forward backtesting framework for SmartScale AI forecasting models.

    Compares LinearRegression and ARIMA side-by-side on the same historical
    data and recommends the better model for the ModelRegistry to persist.

    Example:
        evaluator = ModelEvaluator(
            horizon_steps=3,         # forecast 3 steps ahead
            min_train_size=30,       # minimum training window
            target_queue_length=5,   # for replica calculation
            max_replicas=5,
        )
        result = evaluator.evaluate(historical_depths)
        # result.best_model_name → "arima" or "linear_regression" or "reactive"
    """

    def __init__(
        self,
        horizon_steps: int = 3,
        min_train_size: int = 30,
        target_queue_length: int = 5,
        max_replicas: int = 5,
    ) -> None:
        self._horizon = horizon_steps
        self._min_train = min_train_size
        self._target_queue_length = target_queue_length
        self._max_replicas = max_replicas

    def evaluate(self, historical_depths: List[float]) -> EvaluationResult:
        """
        Run walk-forward backtesting on both models and return a comparison result.

        Args:
            historical_depths: Time-ordered list of SQS queue depth observations.
                               Must have at least min_train_size + horizon_steps entries.

        Returns:
            EvaluationResult with MAPE for each model and the best_model_name.
        """
        start_time = time.monotonic()

        n = len(historical_depths)
        min_needed = self._min_train + self._horizon

        if n < min_needed:
            logger.warning(
                "Insufficient data for backtesting, recommending reactive",
                extra={"have": n, "need": min_needed},
            )
            return EvaluationResult(
                best_model_name="reactive",
                lr_mape=float("inf"),
                arima_mape=float("inf"),
                recommendation=f"Insufficient data ({n} < {min_needed}). Using reactive KEDA.",
                n_backtest_steps=0,
                horizon_steps=self._horizon,
                evaluation_duration_ms=0.0,
            )

        lr_errors = self._backtest_linear_regression(historical_depths)
        arima_errors = self._backtest_arima(historical_depths)

        lr_mape = _mape(lr_errors)
        arima_mape = _mape(arima_errors)

        best_model, recommendation = self._select_best(lr_mape, arima_mape)

        duration_ms = (time.monotonic() - start_time) * 1000

        logger.info(
            "Model evaluation complete",
            extra={
                "best_model": best_model,
                "lr_mape": round(lr_mape, 2),
                "arima_mape": round(arima_mape, 2),
                "n_steps": len(lr_errors),
                "duration_ms": round(duration_ms, 1),
            },
        )

        return EvaluationResult(
            best_model_name=best_model,
            lr_mape=lr_mape,
            arima_mape=arima_mape,
            lr_backtest_errors=lr_errors,
            arima_backtest_errors=arima_errors,
            n_backtest_steps=len(lr_errors),
            horizon_steps=self._horizon,
            evaluation_duration_ms=duration_ms,
            recommendation=recommendation,
        )

    # ── Private helpers ────────────────────────────────────────────────────────

    def _backtest_linear_regression(self, series: List[float]) -> List[float]:
        """Walk-forward backtest for the Linear Regression predictor."""
        from ai.predictor import QueueDepthPredictor

        errors: List[float] = []
        for t in range(self._min_train, len(series) - self._horizon):
            predictor = QueueDepthPredictor(
                horizon_minutes=self._horizon,
                target_queue_length=self._target_queue_length,
                max_replicas=self._max_replicas,
            )
            # Feed training data
            for i, depth in enumerate(series[:t]):
                predictor.record_observation(timestamp=float(i * 60), depth=depth)

            if predictor.is_ready():
                try:
                    predicted = predictor.predict()
                    actual = series[t + self._horizon - 1]
                    errors.append(_ape(actual, predicted.predicted_depth))
                except Exception:
                    pass  # Skip failed predictions

        return errors

    def _backtest_arima(self, series: List[float]) -> List[float]:
        """Walk-forward backtest for the ARIMA predictor."""
        from ai.arima_predictor import ARIMAPredictor

        errors: List[float] = []
        for t in range(self._min_train, len(series) - self._horizon):
            predictor = ARIMAPredictor(
                horizon_steps=self._horizon,
                order=(1, 1, 1),
                target_queue_length=self._target_queue_length,
                max_replicas=self._max_replicas,
                min_observations=self._min_train,
            )
            for depth in series[:t]:
                predictor.record_observation(depth)

            if predictor.is_ready():
                forecast = predictor.predict()
                if not forecast.fallback_used:
                    actual = series[t + self._horizon - 1]
                    errors.append(_ape(actual, forecast.predicted_depth))

        return errors

    def _select_best(self, lr_mape: float, arima_mape: float) -> Tuple[str, str]:
        """Choose the best model and produce a recommendation string."""
        both_poor = (lr_mape > MAPE_FALLBACK_THRESHOLD and arima_mape > MAPE_FALLBACK_THRESHOLD)

        if both_poor:
            return (
                "reactive",
                f"Both models have MAPE > {MAPE_FALLBACK_THRESHOLD}% "
                f"(LR: {lr_mape:.1f}%, ARIMA: {arima_mape:.1f}%). "
                f"Using reactive KEDA (actual queue depth).",
            )

        if arima_mape <= lr_mape:
            winner, loser, winner_mape, loser_mape = "arima", "linear_regression", arima_mape, lr_mape
        else:
            winner, loser, winner_mape, loser_mape = "linear_regression", "arima", lr_mape, arima_mape

        improvement = ((loser_mape - winner_mape) / max(loser_mape, 0.001)) * 100
        return (
            winner,
            f"{winner} wins (MAPE {winner_mape:.1f}% vs {loser_mape:.1f}%, "
            f"{improvement:.0f}% more accurate than {loser}).",
        )


# ── Utility functions ──────────────────────────────────────────────────────────

def _ape(actual: float, predicted: float) -> float:
    """Absolute Percentage Error for one data point. Returns 0 if actual == 0."""
    if actual == 0:
        return 0.0
    return abs(actual - predicted) / abs(actual) * 100.0


def _mape(errors: List[float]) -> float:
    """Mean of a list of APE values. Returns inf if list is empty."""
    if not errors:
        return float("inf")
    return sum(errors) / len(errors)
