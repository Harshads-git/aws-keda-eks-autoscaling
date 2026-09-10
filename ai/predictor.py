"""
ai/predictor.py — Predictive Scaling Model for SmartScale AI
=============================================================
This module implements the AI-based predictive scaling component described
in Review 1's Innovation section. It predicts future SQS queue depth using
a time-series model trained on historical queue observations.

Architecture position:
  Reactive path (current):
    SQS queue → KEDA polls every 15s → HPA scales pods
    Lag: 15-45 seconds from traffic spike to pods ready

  Predictive path (this module):
    Historical queue depth data → predictor.py → predicted future depth
    → KEDA External Scaler → proactive HPA target → pods ready BEFORE spike
    Lag: near-zero (pods pre-warmed)

Model choice — Linear Regression with rolling window features:
  Why not LSTM/deep learning:
    Training data: we have minutes of queue depth observations (not months)
    Deep learning needs thousands of examples; we have dozens
    Linear regression needs 5-10 examples; works well on small datasets

  Why rolling window features:
    Queue depth at t+5 is correlated with depth at t, t-1, t-2 (autocorrelation)
    Rolling mean captures "trend" (rising vs falling queue)
    Rolling std captures "volatility" (bursty vs steady traffic)
    These features let linear regression approximate simple time-series patterns

  Practical scalability:
    This prototype uses scikit-learn (lightweight, no GPU)
    Can be swapped for Prophet (Facebook), statsmodels ARIMA, or PyTorch LSTM
    as data accumulates (see ai-scaling-guide.md)

GCP equivalent:
  The reference GCP project uses Pub/Sub (no built-in depth metric)
  AWS SQS provides ApproximateNumberOfMessages — a direct training signal
  This makes AWS/KEDA a better fit for queue-depth-based predictive scaling

Usage:
    from ai.predictor import QueueDepthPredictor

    predictor = QueueDepthPredictor(horizon_minutes=5)
    predictor.record_observation(timestamp=time.time(), depth=10)
    ...  # record more observations over time
    if predictor.is_ready():
        future_depth = predictor.predict()
        recommended_replicas = predictor.recommended_replicas(future_depth)
"""

from __future__ import annotations

import json
import logging
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np

logger = logging.getLogger(__name__)


# ─── Configuration ─────────────────────────────────────────────────────────────

@dataclass
class PredictorConfig:
    """Configuration for the queue depth predictor."""

    # Prediction horizon: how many minutes ahead to predict
    horizon_minutes: int = 5

    # Minimum observations before the model can predict
    min_observations: int = 10

    # Rolling window size for feature engineering
    window_size: int = 5

    # Maximum observations to keep in memory (sliding window)
    max_history: int = 100

    # KEDA scaling parameters (mirrors keda-scaled-object.yaml)
    target_queue_length: int = 5   # 1 pod per N messages
    max_replicas: int = 5          # ceiling on recommended pods

    # Conservative buffer: pre-scale to handle predicted_depth * buffer
    prediction_buffer: float = 1.2  # scale for predicted_depth * 1.2

    # Observation interval (how often queue depth is sampled, in seconds)
    observation_interval_s: int = 15  # matches KEDA pollingInterval


@dataclass
class Observation:
    """A single queue depth measurement."""
    timestamp: float  # Unix epoch seconds
    depth: int        # ApproximateNumberOfMessages


@dataclass
class PredictionResult:
    """Output from the predictor."""
    predicted_depth: float
    recommended_replicas: int
    confidence: float          # 0.0 (low) to 1.0 (high)
    model_type: str
    features_used: list[str]
    timestamp: float = field(default_factory=time.time)
    horizon_minutes: int = 5

    def to_dict(self) -> dict:
        return {
            "predicted_depth": round(self.predicted_depth, 2),
            "recommended_replicas": self.recommended_replicas,
            "confidence": round(self.confidence, 3),
            "model_type": self.model_type,
            "horizon_minutes": self.horizon_minutes,
            "timestamp": self.timestamp,
        }


# ─── Feature Engineering ──────────────────────────────────────────────────────

def build_features(depths: list[int], window: int = 5) -> dict[str, float]:
    """
    Build time-series features from a sequence of queue depth observations.

    Features:
        current_depth:  most recent observation
        lag_1, lag_2:   previous observations (autocorrelation)
        rolling_mean:   average over last 'window' observations (trend)
        rolling_std:    std dev over last 'window' observations (volatility)
        delta_1:        change from lag_1 to current (velocity)
        delta_2:        change from lag_2 to lag_1 (acceleration)

    Args:
        depths: list of recent queue depth values, oldest first
        window: size of rolling window for mean/std features

    Returns:
        dict of feature_name -> value
    """
    if len(depths) < 2:
        return {"current_depth": float(depths[-1])} if depths else {}

    arr = np.array(depths, dtype=float)
    current = arr[-1]
    lag1 = arr[-2] if len(arr) >= 2 else current
    lag2 = arr[-3] if len(arr) >= 3 else lag1

    window_slice = arr[-window:] if len(arr) >= window else arr
    rolling_mean = float(np.mean(window_slice))
    rolling_std = float(np.std(window_slice))

    delta_1 = current - lag1
    delta_2 = lag1 - lag2

    return {
        "current_depth":  current,
        "lag_1":          lag1,
        "lag_2":          lag2,
        "rolling_mean":   rolling_mean,
        "rolling_std":    rolling_std,
        "delta_1":        delta_1,
        "delta_2":        delta_2,
    }


def features_to_vector(features: dict[str, float]) -> np.ndarray:
    """Convert feature dict to a numpy array for sklearn."""
    keys = ["current_depth", "lag_1", "lag_2", "rolling_mean", "rolling_std",
            "delta_1", "delta_2"]
    return np.array([features.get(k, 0.0) for k in keys])


# ─── Core Predictor ───────────────────────────────────────────────────────────

class QueueDepthPredictor:
    """
    Predicts future SQS queue depth using a linear regression model
    trained on rolling window features.

    Thread-safety: NOT thread-safe. Call from a single monitoring thread.
    """

    def __init__(self, config: Optional[PredictorConfig] = None):
        self.config = config or PredictorConfig()
        self._observations: deque[Observation] = deque(
            maxlen=self.config.max_history
        )
        self._model = None         # sklearn LinearRegression (lazy init)
        self._model_trained = False
        self._training_r2 = 0.0
        self._prediction_count = 0
        self._last_prediction: Optional[PredictionResult] = None
        logger.info(
            "QueueDepthPredictor initialized",
            extra={
                "horizon_minutes": self.config.horizon_minutes,
                "min_observations": self.config.min_observations,
                "window_size": self.config.window_size,
            }
        )

    def record_observation(self, depth: int, timestamp: Optional[float] = None) -> None:
        """
        Record a queue depth observation. Call every observation_interval_s.

        Args:
            depth: current SQS ApproximateNumberOfMessages value
            timestamp: Unix epoch seconds (defaults to now)
        """
        if timestamp is None:
            timestamp = time.time()
        obs = Observation(timestamp=timestamp, depth=max(0, depth))
        self._observations.append(obs)
        logger.debug("Observation recorded", extra={"depth": depth, "total": len(self._observations)})

        # Re-train model whenever we have enough data (lightweight, fast)
        if len(self._observations) >= self.config.min_observations:
            self._train()

    def is_ready(self) -> bool:
        """Returns True when the model has enough data to make predictions."""
        return self._model_trained and len(self._observations) >= self.config.min_observations

    def predict(self) -> Optional[PredictionResult]:
        """
        Predict queue depth horizon_minutes into the future.

        Returns:
            PredictionResult or None if not enough data yet.
        """
        if not self.is_ready():
            logger.debug(
                "Predictor not ready",
                extra={
                    "observations": len(self._observations),
                    "required": self.config.min_observations,
                    "model_trained": self._model_trained,
                }
            )
            return None

        depths = [obs.depth for obs in self._observations]
        features = build_features(depths, self.config.window_size)
        x = features_to_vector(features).reshape(1, -1)

        raw_prediction = float(self._model.predict(x)[0])
        # Queue depth is never negative
        predicted_depth = max(0.0, raw_prediction)

        # Apply buffer for conservative pre-scaling
        buffered_depth = predicted_depth * self.config.prediction_buffer

        recommended = self._depth_to_replicas(buffered_depth)
        confidence = self._compute_confidence()

        result = PredictionResult(
            predicted_depth=predicted_depth,
            recommended_replicas=recommended,
            confidence=confidence,
            model_type="LinearRegressionRollingWindow",
            features_used=list(features.keys()),
            horizon_minutes=self.config.horizon_minutes,
        )
        self._last_prediction = result
        self._prediction_count += 1

        logger.info(
            "Prediction made",
            extra={
                "predicted_depth": round(predicted_depth, 2),
                "recommended_replicas": recommended,
                "confidence": round(confidence, 3),
                "r2_score": round(self._training_r2, 3),
            }
        )
        return result

    def _train(self) -> None:
        """
        Train (or retrain) the Linear Regression model on all observations.

        The model learns: features(t) → depth(t + horizon_steps)
        where horizon_steps = horizon_minutes * (60 / observation_interval_s)
        """
        try:
            # Lazy import sklearn (not required if predictor not used)
            from sklearn.linear_model import LinearRegression
            from sklearn.metrics import r2_score
        except ImportError:
            logger.warning("scikit-learn not installed. Install: pip install scikit-learn")
            return

        depths = [obs.depth for obs in self._observations]
        horizon_steps = max(1, int(
            self.config.horizon_minutes * 60 / self.config.observation_interval_s
        ))

        # Build training samples: X = features at step t, y = depth at step t+horizon
        X_rows, y_values = [], []
        for i in range(len(depths) - horizon_steps):
            window_depths = depths[max(0, i - self.config.window_size + 1): i + 1]
            if len(window_depths) < 2:
                continue
            feats = build_features(window_depths, self.config.window_size)
            X_rows.append(features_to_vector(feats))
            y_values.append(float(depths[i + horizon_steps]))

        if len(X_rows) < 3:
            return  # Need at least 3 samples to fit

        X = np.array(X_rows)
        y = np.array(y_values)

        model = LinearRegression()
        model.fit(X, y)
        self._training_r2 = r2_score(y, model.predict(X))
        self._model = model
        self._model_trained = True

        logger.debug(
            "Model retrained",
            extra={
                "samples": len(X_rows),
                "r2_score": round(self._training_r2, 3),
                "horizon_steps": horizon_steps,
            }
        )

    def _depth_to_replicas(self, depth: float) -> int:
        """
        Convert predicted queue depth to recommended replica count.
        Mirrors KEDA's ceil(depth / targetQueueLength) formula.
        """
        import math
        if depth <= 0:
            return 0
        replicas = math.ceil(depth / self.config.target_queue_length)
        return min(replicas, self.config.max_replicas)

    def _compute_confidence(self) -> float:
        """
        Confidence score [0.0, 1.0] based on model R² and observation count.
        Higher R² and more observations = higher confidence.
        """
        r2_confidence = max(0.0, min(1.0, self._training_r2))
        data_confidence = min(1.0, len(self._observations) / (self.config.max_history * 0.5))
        return (r2_confidence * 0.7) + (data_confidence * 0.3)

    def summary(self) -> dict:
        """Return a summary of predictor state (for logging/Prometheus)."""
        return {
            "observations": len(self._observations),
            "model_trained": self._model_trained,
            "training_r2": round(self._training_r2, 3),
            "predictions_made": self._prediction_count,
            "is_ready": self.is_ready(),
            "last_prediction": (
                self._last_prediction.to_dict() if self._last_prediction else None
            ),
        }

    def save_history(self, path: str) -> None:
        """Persist observation history to JSON for offline analysis."""
        data = [
            {"timestamp": obs.timestamp, "depth": obs.depth}
            for obs in self._observations
        ]
        Path(path).write_text(json.dumps(data, indent=2))
        logger.info(f"Saved {len(data)} observations to {path}")

    @classmethod
    def load_history(
        cls,
        path: str,
        config: Optional[PredictorConfig] = None,
    ) -> "QueueDepthPredictor":
        """Load a predictor pre-populated with historical observations."""
        predictor = cls(config)
        data = json.loads(Path(path).read_text())
        for entry in data:
            predictor.record_observation(
                depth=entry["depth"], timestamp=entry["timestamp"]
            )
        logger.info(f"Loaded {len(data)} observations from {path}")
        return predictor


# ─── Standalone Demo ──────────────────────────────────────────────────────────

if __name__ == "__main__":
    """
    Demo: simulate a rising queue depth and show predictions.

    Run: python ai/predictor.py
    """
    import math
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    config = PredictorConfig(
        horizon_minutes=5,
        min_observations=10,
        observation_interval_s=15,
    )
    predictor = QueueDepthPredictor(config)

    print("\n🤖 SmartScale AI — Predictive Scaling Demo")
    print("=" * 55)
    print("Simulating queue depth: 30-minute traffic ramp-up")
    print(f"{'Step':>5} {'Depth':>8} {'Predicted':>10} {'Reactive':>10} {'Predictive':>12}")
    print("-" * 55)

    # Simulate 30 minutes of observations (every 15s = 120 steps)
    for step in range(120):
        t = step * 15  # seconds from start

        # Simulate realistic queue depth: ramp up at t=10min, ramp down at t=20min
        if t < 600:
            depth = max(0, int(5 * math.sin(t / 200) + 2))
        elif t < 1200:
            depth = max(0, int(20 * math.sin((t - 600) / 150) + 10))
        else:
            depth = max(0, int(5 * math.exp(-(t - 1200) / 300)))

        predictor.record_observation(depth=depth, timestamp=float(t))

        # Reactive KEDA: ceil(current / targetQueueLength)
        reactive_replicas = min(5, max(0, math.ceil(depth / 5)))

        if predictor.is_ready():
            result = predictor.predict()
            if result:
                pred_replicas = result.recommended_replicas
                print(
                    f"{step:>5} {depth:>8} {result.predicted_depth:>10.1f} "
                    f"{reactive_replicas:>10} {pred_replicas:>12}"
                    f"  conf={result.confidence:.2f}"
                )
        elif step % 5 == 0:
            print(
                f"{step:>5} {depth:>8} {'(warming up)':>10} "
                f"{reactive_replicas:>10} {'(warming up)':>12}"
            )

    print("\n" + "=" * 55)
    print("Summary:", json.dumps(predictor.summary(), indent=2))
