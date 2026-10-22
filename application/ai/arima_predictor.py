"""
ai/arima_predictor.py — ARIMA Time-Series Forecasting for SmartScale AI
=========================================================================

Implements ARIMA (AutoRegressive Integrated Moving Average) as an alternative
to the Linear Regression predictor in ai/predictor.py.

Why ARIMA vs Linear Regression?
  Linear Regression with rolling features:
    + Needs only 10-15 data points to train
    + Fast training (<1ms), deterministic
    - Assumes linear trend — poor for non-linear traffic bursts
    - No concept of time dependency built-in (features are manual)

  ARIMA(p, d, q):
    + Designed specifically for time-series with autocorrelation
    + Captures seasonality patterns (morning/evening spikes)
    + Handles non-stationary data via differencing (the 'd' parameter)
    - Needs 30-50+ data points for reliable estimation
    - Slower training (~10-100ms), stochastic if using auto_arima

ARIMA(1, 1, 1) — our configuration:
  p=1: AutoRegressive — current depth depends on 1 previous depth
       "If the queue was growing last minute, it's likely still growing"
  d=1: Integrated — first-order differencing removes linear trends
       "Operate on changes (delta depth) instead of raw depth values"
  q=1: Moving Average — incorporate 1 prior forecast error into model
       "Correct for how wrong our last prediction was"

Usage:
    from ai.arima_predictor import ARIMAPredictor

    predictor = ARIMAPredictor(horizon_steps=3, order=(1, 1, 1))
    predictor.record_observation(depth=10)
    predictor.record_observation(depth=15)
    # ... record at least 30 observations ...
    if predictor.is_ready():
        result = predictor.predict()
        print(result.predicted_depth)     # → e.g. 42
        print(result.recommended_replicas) # → e.g. 9
        print(result.confidence)          # → 0.0 - 1.0
"""

import logging
import time
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

logger = logging.getLogger("keda-demo")

# Minimum observations before ARIMA can produce a reliable forecast.
# ARIMA(1,1,1) needs at least: max(p,d,q) + seasonal period + forecast horizon.
# We use 30 to ensure sufficient degrees of freedom for stable parameter estimation.
MIN_OBSERVATIONS = 30

# Maximum history to keep in memory. Older data is less relevant for
# short-term queue depth prediction. 500 = ~8 hours at 1 obs/min.
MAX_HISTORY_SIZE = 500


@dataclass
class ARIMAForecast:
    """
    Result returned by ARIMAPredictor.predict().

    All fields are populated when prediction succeeds.
    On failure (insufficient data, import error), fallback_used=True
    and predicted_depth equals the most recent observation.
    """
    predicted_depth: float
    """Forecasted SQS queue depth at t+horizon_steps."""

    recommended_replicas: int
    """ceil(predicted_depth / target_queue_length_per_pod)."""

    confidence: float
    """
    Score in [0.0, 1.0] derived from the AIC residual mean squared error.
    Higher = more reliable forecast.
    0.0: model has not converged or data is insufficient.
    0.5: borderline — model should be verified against actuals.
    1.0: high confidence — forecast residuals are very small.
    """

    model_order: Tuple[int, int, int] = (1, 1, 1)
    """ARIMA (p, d, q) order used for this forecast."""

    forecast_horizon_steps: int = 3
    """Number of steps ahead that predicted_depth represents."""

    observations_used: int = 0
    """Number of data points the model was trained on."""

    fallback_used: bool = False
    """True when ARIMA failed and the most recent observation was returned."""

    error_message: Optional[str] = None
    """Set if fallback_used=True — explains why prediction failed."""


class ARIMAPredictor:
    """
    ARIMA-based time-series predictor for SQS queue depth.

    Drop-in complement to QueueDepthPredictor (Linear Regression).
    The ModelEvaluator (ai/model_evaluator.py) compares both models
    on historical data and selects the most accurate one.

    Example:
        predictor = ARIMAPredictor(
            horizon_steps=3,       # predict 3 steps (minutes) ahead
            order=(1, 1, 1),       # ARIMA(p=1, d=1, q=1)
            target_queue_length=5, # pods = ceil(depth / 5)
            max_replicas=5,        # never exceed 5 pods
        )
        predictor.record_observation(12)
        predictor.record_observation(18)
        # ... keep recording every minute ...
        if predictor.is_ready():
            forecast = predictor.predict()
    """

    def __init__(
        self,
        horizon_steps: int = 3,
        order: Tuple[int, int, int] = (1, 1, 1),
        target_queue_length: int = 5,
        max_replicas: int = 5,
        min_observations: int = MIN_OBSERVATIONS,
    ) -> None:
        """
        Args:
            horizon_steps: How many steps ahead to forecast. Each step = one
                interval (typically the KEDA polling interval, e.g. 15 seconds
                or 1 minute if observations are taken per-minute).
            order: ARIMA (p, d, q) parameters.
                p (AR): lags to include as predictors.
                d (I): differencing order to achieve stationarity.
                q (MA): lagged forecast errors to include.
            target_queue_length: Messages-per-pod threshold used to compute
                recommended_replicas from the predicted depth.
            max_replicas: Hard cap on recommended_replicas.
            min_observations: Minimum observations needed before is_ready().
        """
        self._horizon_steps = horizon_steps
        self._order = order
        self._target_queue_length = target_queue_length
        self._max_replicas = max_replicas
        self._min_observations = min_observations

        self._observations: List[float] = []
        self._timestamps: List[float] = []

        # Track the last prediction for logging and comparison
        self._last_forecast: Optional[ARIMAForecast] = None

    def record_observation(self, depth: float, timestamp: Optional[float] = None) -> None:
        """
        Record a new SQS queue depth observation.

        Call this periodically (e.g., every KEDA polling interval) with the
        current ApproximateNumberOfMessages value.

        Args:
            depth: Current SQS queue depth (>= 0).
            timestamp: Unix timestamp. Defaults to time.time().
        """
        if timestamp is None:
            timestamp = time.time()

        self._observations.append(max(0.0, float(depth)))
        self._timestamps.append(timestamp)

        # Trim to rolling window to prevent unbounded memory growth
        if len(self._observations) > MAX_HISTORY_SIZE:
            self._observations = self._observations[-MAX_HISTORY_SIZE:]
            self._timestamps = self._timestamps[-MAX_HISTORY_SIZE:]

    def is_ready(self) -> bool:
        """Return True when enough observations are available to fit the model."""
        return len(self._observations) >= self._min_observations

    def predict(self) -> ARIMAForecast:
        """
        Fit ARIMA on the recorded observations and forecast horizon_steps ahead.

        Returns:
            ARIMAForecast with predicted depth, replica recommendation, and
            confidence score. Falls back to the last observation if ARIMA
            cannot produce a forecast (insufficient data, import error,
            numerical instability).
        """
        current_depth = self._observations[-1] if self._observations else 0.0

        if not self.is_ready():
            return ARIMAForecast(
                predicted_depth=current_depth,
                recommended_replicas=self._replicas_for(current_depth),
                confidence=0.0,
                model_order=self._order,
                forecast_horizon_steps=self._horizon_steps,
                observations_used=len(self._observations),
                fallback_used=True,
                error_message=f"Need {self._min_observations} observations, "
                              f"have {len(self._observations)}",
            )

        try:
            return self._fit_and_forecast()
        except ImportError as e:
            logger.warning("statsmodels not installed, using fallback", extra={"error": str(e)})
            return ARIMAForecast(
                predicted_depth=current_depth,
                recommended_replicas=self._replicas_for(current_depth),
                confidence=0.0,
                model_order=self._order,
                forecast_horizon_steps=self._horizon_steps,
                observations_used=len(self._observations),
                fallback_used=True,
                error_message="statsmodels not installed",
            )
        except Exception as e:
            logger.warning(
                "ARIMA forecasting failed, using fallback",
                extra={"error": str(e), "observations": len(self._observations)},
            )
            return ARIMAForecast(
                predicted_depth=current_depth,
                recommended_replicas=self._replicas_for(current_depth),
                confidence=0.0,
                model_order=self._order,
                forecast_horizon_steps=self._horizon_steps,
                observations_used=len(self._observations),
                fallback_used=True,
                error_message=str(e),
            )

    def _fit_and_forecast(self) -> ARIMAForecast:
        """Internal: fit ARIMA and return a populated ARIMAForecast."""
        from statsmodels.tsa.arima.model import ARIMA  # type: ignore
        import warnings
        import numpy as np

        series = self._observations[:]

        # Suppress convergence warnings for cleaner logs (expected with small data)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            p, d, q = self._order
            model = ARIMA(series, order=(p, d, q))
            result = model.fit()

        # Forecast horizon_steps ahead
        # get_forecast returns a ForecastResults object with mean and confidence intervals
        forecast_result = result.get_forecast(steps=self._horizon_steps)
        forecast_mean = forecast_result.predicted_mean

        # The final step in the horizon is our prediction
        predicted_depth = max(0.0, float(forecast_mean.iloc[-1]))

        # Confidence: derived from normalized residual MSE.
        # AIC alone isn't a 0-1 score; we use rmse / mean_depth as relative error.
        import numpy as np
        residuals = result.resid
        rmse = float(np.sqrt(np.mean(residuals**2)))
        mean_depth = max(1.0, float(np.mean(series)))
        relative_error = rmse / mean_depth

        # Map relative_error → confidence:
        #   relative_error < 0.05 → confidence ≈ 1.0 (error < 5% of mean)
        #   relative_error = 0.50 → confidence ≈ 0.5
        #   relative_error > 1.00 → confidence ≈ 0.0
        confidence = float(max(0.0, min(1.0, 1.0 - relative_error)))

        forecast = ARIMAForecast(
            predicted_depth=predicted_depth,
            recommended_replicas=self._replicas_for(predicted_depth),
            confidence=confidence,
            model_order=self._order,
            forecast_horizon_steps=self._horizon_steps,
            observations_used=len(self._observations),
            fallback_used=False,
        )
        self._last_forecast = forecast

        logger.info(
            "ARIMA forecast complete",
            extra={
                "predicted_depth": round(predicted_depth, 2),
                "recommended_replicas": forecast.recommended_replicas,
                "confidence": round(confidence, 3),
                "observations_used": len(self._observations),
                "order": f"ARIMA{self._order}",
            },
        )
        return forecast

    def _replicas_for(self, depth: float) -> int:
        """Convert a queue depth into a replica count using the KEDA formula."""
        import math
        if depth <= 0:
            return 0
        replicas = math.ceil(depth / self._target_queue_length)
        return min(replicas, self._max_replicas)

    @property
    def observation_count(self) -> int:
        """Number of observations currently stored."""
        return len(self._observations)

    @property
    def last_forecast(self) -> Optional[ARIMAForecast]:
        """The most recent successful forecast, or None."""
        return self._last_forecast
