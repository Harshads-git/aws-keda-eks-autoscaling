"""
application/prediction_api.py — FastAPI Prediction Endpoint for SmartScale AI
===============================================================================

HTTP API that serves live scaling recommendations from the AI predictive model.

Why an HTTP API for predictions?
  The ai/predictor.py model runs inside a Python process. KEDA's External
  Scaler calls gRPC, not Python directly. The standard integration pattern is:

    ai/predictor.py (model) → prediction_api.py (HTTP server) → KEDA External Scaler

  KEDA External Scaler queries: GET /predict?queue_depth=25
  Response: {"recommended_replicas": 5, "predicted_depth": 25.0, "confidence": 0.87}
  KEDA uses recommended_replicas as the target metric value.

Endpoints:
  GET  /health             → Liveness probe (returns {"status": "ok"})
  GET  /ready              → Readiness probe (model loaded and ready)
  GET  /predict            → Main endpoint: returns scaling recommendation
  POST /observe            → Record a new queue depth observation for training
  GET  /model/info         → Current model metadata (name, MAPE, version)
  GET  /metrics            → Prometheus metrics (text/plain)

Usage:
    # Run locally
    python prediction_api.py

    # Or via uvicorn
    uvicorn prediction_api:app --host 0.0.0.0 --port 8090

    # Query
    curl "http://localhost:8090/predict?queue_depth=20"
    curl -X POST "http://localhost:8090/observe" -d '{"depth": 20}'

Environment Variables:
    API_HOST:                 Bind host (default: 0.0.0.0)
    API_PORT:                 Bind port (default: 8090)
    MODEL_TYPE:               'linear_regression' or 'arima' (default: linear_regression)
    HORIZON_MINUTES:          Forecast horizon steps (default: 3)
    TARGET_QUEUE_LENGTH:      Messages per pod (default: 5)
    MAX_REPLICAS:             Max pod count (default: 5)
    CONFIDENCE_THRESHOLD:     Min confidence to use AI vs reactive (default: 0.5)
"""

import logging
import os
import sys
import time
from contextlib import asynccontextmanager
from dataclasses import asdict
from typing import Optional

# FastAPI imports — imported at runtime to keep the app startable without these
# in environments where they haven't been installed yet.
try:
    from fastapi import FastAPI, HTTPException, Query
    from fastapi.responses import PlainTextResponse
    from pydantic import BaseModel
    import uvicorn
    FASTAPI_AVAILABLE = True
except ImportError:
    FASTAPI_AVAILABLE = False

from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)
from pythonjsonlogger import jsonlogger

# ─── Logging ──────────────────────────────────────────────────────────────────

def _setup_logging() -> logging.Logger:
    logger = logging.getLogger("prediction-api")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    return logger


logger = _setup_logging()

# ─── Prometheus Metrics ───────────────────────────────────────────────────────

PREDICT_REQUESTS = Counter(
    "prediction_api_requests_total",
    "Total prediction requests served",
    ["model_type", "used_ai"],
)
PREDICT_LATENCY = Histogram(
    "prediction_api_latency_seconds",
    "Time to serve a prediction request",
    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5],
)
RECOMMENDED_REPLICAS = Gauge(
    "prediction_api_recommended_replicas",
    "Most recently recommended replica count from the AI model",
)
OBSERVATIONS_RECORDED = Counter(
    "prediction_api_observations_total",
    "Total queue depth observations recorded",
)
AI_CONFIDENCE = Gauge(
    "prediction_api_model_confidence",
    "Confidence score of the most recent AI prediction (0.0 - 1.0)",
)

# ─── Configuration ────────────────────────────────────────────────────────────

class APIConfig:
    host: str = os.environ.get("API_HOST", "0.0.0.0")
    port: int = int(os.environ.get("API_PORT", "8090"))
    model_type: str = os.environ.get("MODEL_TYPE", "linear_regression")
    horizon_minutes: int = int(os.environ.get("HORIZON_MINUTES", "3"))
    target_queue_length: int = int(os.environ.get("TARGET_QUEUE_LENGTH", "5"))
    max_replicas: int = int(os.environ.get("MAX_REPLICAS", "5"))
    confidence_threshold: float = float(os.environ.get("CONFIDENCE_THRESHOLD", "0.5"))


# ─── Global model state ───────────────────────────────────────────────────────

_predictor = None
_model_type = "linear_regression"
_config = APIConfig()


def _init_predictor():
    """Initialise the predictor based on MODEL_TYPE env var."""
    global _predictor, _model_type

    _model_type = _config.model_type

    if _model_type == "arima":
        try:
            from ai.arima_predictor import ARIMAPredictor
            _predictor = ARIMAPredictor(
                horizon_steps=_config.horizon_minutes,
                target_queue_length=_config.target_queue_length,
                max_replicas=_config.max_replicas,
            )
            logger.info("ARIMA predictor initialised")
        except ImportError:
            logger.warning("ARIMA unavailable, falling back to linear regression")
            _model_type = "linear_regression"

    if _model_type == "linear_regression" or _predictor is None:
        from ai.predictor import QueueDepthPredictor
        _predictor = QueueDepthPredictor(
            horizon_minutes=_config.horizon_minutes,
            target_queue_length=_config.target_queue_length,
            max_replicas=_config.max_replicas,
        )
        _model_type = "linear_regression"
        logger.info("Linear Regression predictor initialised")


# ─── Pydantic models ──────────────────────────────────────────────────────────

class ObserveRequest(BaseModel):
    depth: float
    timestamp: Optional[float] = None


class PredictResponse(BaseModel):
    recommended_replicas: int
    predicted_depth: float
    confidence: float
    model_type: str
    used_ai: bool
    observations_count: int
    horizon_steps: int


class ModelInfoResponse(BaseModel):
    model_type: str
    is_ready: bool
    observation_count: int
    horizon_steps: int
    target_queue_length: int
    max_replicas: int
    confidence_threshold: float


# ─── Application factory ──────────────────────────────────────────────────────

def create_app() -> "FastAPI":
    """Create and configure the FastAPI application."""

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        """Initialise the predictor on startup."""
        _init_predictor()
        logger.info(
            "Prediction API started",
            extra={"model_type": _model_type, "port": _config.port},
        )
        yield
        logger.info("Prediction API shutting down")

    app = FastAPI(
        title="SmartScale AI — Prediction API",
        description="Serves AI-based scaling recommendations for KEDA External Scaler.",
        version="1.0.0",
        lifespan=lifespan,
    )

    # ── Health endpoints ───────────────────────────────────────────────────────

    @app.get("/health", tags=["health"])
    async def health():
        """Kubernetes liveness probe — always returns 200 if process is alive."""
        return {"status": "ok"}

    @app.get("/ready", tags=["health"])
    async def ready():
        """Kubernetes readiness probe — 200 only if predictor is initialised."""
        if _predictor is None:
            raise HTTPException(status_code=503, detail="Predictor not initialised")
        return {"status": "ready", "model_type": _model_type}

    # ── Prediction endpoint ────────────────────────────────────────────────────

    @app.get("/predict", response_model=PredictResponse, tags=["prediction"])
    async def predict(
        queue_depth: float = Query(
            ...,
            description="Current SQS queue depth (ApproximateNumberOfMessages)",
            ge=0,
        )
    ):
        """
        Return an AI-based scaling recommendation for the given queue depth.

        The API first records the queue_depth as an observation, then calls
        the predictor. If the model is not yet ready (insufficient history) or
        confidence is below the threshold, the response uses the reactive formula:
            recommended_replicas = ceil(queue_depth / target_queue_length)
        """
        start = time.monotonic()

        if _predictor is None:
            raise HTTPException(status_code=503, detail="Predictor not ready")

        # Record observation for continuous model training
        if hasattr(_predictor, "record_observation"):
            _predictor.record_observation(
                depth=queue_depth,
                timestamp=time.time(),
            )
        OBSERVATIONS_RECORDED.inc()

        # Get prediction
        import math
        used_ai = False
        confidence = 0.0

        if _predictor.is_ready():
            try:
                forecast = _predictor.predict()
                confidence = getattr(forecast, "confidence", 0.0)

                if confidence >= _config.confidence_threshold:
                    recommended = forecast.recommended_replicas
                    predicted_depth = getattr(forecast, "predicted_depth", queue_depth)
                    used_ai = True
                else:
                    # Low confidence: fall back to reactive
                    recommended = min(
                        math.ceil(queue_depth / _config.target_queue_length),
                        _config.max_replicas,
                    )
                    predicted_depth = queue_depth
            except Exception as e:
                logger.warning("Prediction failed, using reactive", extra={"error": str(e)})
                recommended = min(
                    math.ceil(queue_depth / _config.target_queue_length),
                    _config.max_replicas,
                )
                predicted_depth = queue_depth
        else:
            # Not enough data yet: reactive scaling
            recommended = min(
                math.ceil(queue_depth / _config.target_queue_length) if queue_depth > 0 else 0,
                _config.max_replicas,
            )
            predicted_depth = queue_depth

        obs_count = getattr(_predictor, "observation_count", 0)

        # Update Prometheus metrics
        PREDICT_REQUESTS.labels(
            model_type=_model_type,
            used_ai=str(used_ai).lower(),
        ).inc()
        RECOMMEND_REPLICAS_gauge(recommended)
        AI_CONFIDENCE.set(confidence)

        duration = time.monotonic() - start
        PREDICT_LATENCY.observe(duration)

        logger.info(
            "Prediction served",
            extra={
                "queue_depth": queue_depth,
                "recommended_replicas": recommended,
                "confidence": round(confidence, 3),
                "used_ai": used_ai,
                "latency_ms": round(duration * 1000, 2),
            },
        )

        return PredictResponse(
            recommended_replicas=recommended,
            predicted_depth=predicted_depth,
            confidence=round(confidence, 4),
            model_type=_model_type,
            used_ai=used_ai,
            observations_count=obs_count,
            horizon_steps=_config.horizon_minutes,
        )

    # ── Observe endpoint ───────────────────────────────────────────────────────

    @app.post("/observe", tags=["prediction"])
    async def observe(body: ObserveRequest):
        """
        Record a queue depth observation without returning a prediction.

        Used by background scrapers to keep the model trained continuously
        even during periods without /predict calls.
        """
        if _predictor is None:
            raise HTTPException(status_code=503, detail="Predictor not ready")

        ts = body.timestamp or time.time()
        _predictor.record_observation(depth=body.depth, timestamp=ts)
        OBSERVATIONS_RECORDED.inc()

        obs_count = getattr(_predictor, "observation_count", 0)
        return {
            "recorded": True,
            "depth": body.depth,
            "observation_count": obs_count,
            "model_ready": _predictor.is_ready(),
        }

    # ── Model info endpoint ────────────────────────────────────────────────────

    @app.get("/model/info", response_model=ModelInfoResponse, tags=["model"])
    async def model_info():
        """Return current model metadata."""
        obs_count = getattr(_predictor, "observation_count", 0) if _predictor else 0
        is_ready = _predictor.is_ready() if _predictor else False
        return ModelInfoResponse(
            model_type=_model_type,
            is_ready=is_ready,
            observation_count=obs_count,
            horizon_steps=_config.horizon_minutes,
            target_queue_length=_config.target_queue_length,
            max_replicas=_config.max_replicas,
            confidence_threshold=_config.confidence_threshold,
        )

    # ── Prometheus metrics ─────────────────────────────────────────────────────

    @app.get("/metrics", tags=["observability"])
    async def metrics():
        """Prometheus metrics in text exposition format."""
        return PlainTextResponse(
            generate_latest().decode("utf-8"),
            media_type=CONTENT_TYPE_LATEST,
        )

    return app


def RECOMMEND_REPLICAS_gauge(value: int):
    """Helper to update the recommended replicas gauge."""
    RECOMMENDED_REPLICAS.set(value)


# ─── Entrypoint ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not FASTAPI_AVAILABLE:
        logger.error("FastAPI / uvicorn not installed. Run: pip install fastapi uvicorn")
        sys.exit(1)

    app = create_app()
    uvicorn.run(
        app,
        host=_config.host,
        port=_config.port,
        log_level="warning",  # Suppress uvicorn access logs (we have structured logging)
    )
