"""
ai/keda_external_scaler_stub.py — KEDA External Scaler Integration
====================================================================
This module shows how predictor.py plugs into KEDA as an External Scaler.

KEDA External Scaler protocol:
  KEDA supports custom metric sources via a gRPC API (external-scaler.proto).
  Any gRPC server that implements the ExternalScaler service can be used as
  a KEDA trigger. KEDA polls the server every pollingInterval seconds.

Architecture when external scaler is deployed:

  Prometheus     ──────────────────────────────────┐
  (historical                                       │
   SQS metrics)                                     ▼
                                          ┌──────────────────────┐
  SQS                 poll every 15s      │  External Scaler     │
  GetQueueAttributes ───────────────────► │  (this module)       │
                                          │                      │
                                          │  QueueDepthPredictor │
                                          │  .predict()          │
                                          └──────────┬───────────┘
                                                     │ GetMetricSpec + GetMetrics
                                                     │ (gRPC, every pollingInterval)
                                                     ▼
                                              KEDA Operator
                                                     │
                                                     ▼
                                              HPA desiredReplicas
                                              = predicted replicas
                                                     │
                                                     ▼
                                          Consumer Deployment

This is a STUB — it shows the integration pattern without requiring
a full gRPC build environment. The gRPC service method signatures
are documented as Python function stubs with full docstrings.

To build the real external scaler:
    1. Install grpcio + grpcio-tools: pip install grpcio grpcio-tools
    2. Download external-scaler.proto from KEDA repo
    3. Generate stubs: python -m grpc_tools.protoc ...
    4. Replace the stub methods below with real implementations
    5. Deploy as a K8s Service (see ScaledObject below)

Reference: https://keda.sh/docs/2.13/concepts/external-scalers/
"""

from __future__ import annotations

import json
import logging
import math
import os
import threading
import time
from dataclasses import dataclass
from typing import Any, Optional

import boto3

from predictor import PredictorConfig, QueueDepthPredictor

logger = logging.getLogger(__name__)


# ─── gRPC Proto Stubs (documentation only) ───────────────────────────────────
# These mirror the actual KEDA external-scaler.proto messages.
# In production: replace with grpc_tools.protoc-generated classes.

@dataclass
class ScaledObjectRef:
    """Reference to the KEDA ScaledObject being served."""
    name: str
    namespace: str


@dataclass
class IsActiveResponse:
    """
    Response to KEDA's IsActive RPC call.
    KEDA calls this to decide whether to allow scale-to-zero.
    If result=False and minReplicaCount=0: KEDA scales to 0 replicas.
    """
    result: bool


@dataclass
class GetMetricSpecResponse:
    """
    Response to KEDA's GetMetricSpec RPC call.
    Declares the metric name and target value this scaler provides.
    """
    metric_specs: list[dict]  # [{"metricName": str, "targetSize": int}]


@dataclass
class GetMetricsResponse:
    """
    Response to KEDA's GetMetrics RPC call.
    The actual metric value that KEDA uses to compute desiredReplicas.
    KEDA formula: desiredReplicas = ceil(metricValue / targetSize)
    """
    metric_values: list[dict]  # [{"metricName": str, "metricValue": int}]


# ─── External Scaler Server ───────────────────────────────────────────────────

class PredictiveExternalScaler:
    """
    KEDA External Scaler that exposes predicted queue depth as a custom metric.

    This server implements the 4 gRPC methods KEDA expects:
      - IsActive:     should KEDA allow scale-to-zero?
      - GetMetricSpec: what metric name and target does this scaler use?
      - GetMetrics:   what is the current metric value?
      - StreamIsActive: streaming version (optional, for push-based scalers)

    KEDA uses GetMetrics() response to compute:
      desiredReplicas = ceil(metricValue / targetSize)

    Our scaler:
      metricValue = predicted_queue_depth (from QueueDepthPredictor)
      targetSize = target_queue_length (e.g. 5 messages per pod)
      → desiredReplicas = ceil(predicted / 5) → pods pre-warmed BEFORE spike
    """

    METRIC_NAME = "predictedQueueDepth"

    def __init__(
        self,
        queue_url: str,
        aws_region: str = "us-east-1",
        config: Optional[PredictorConfig] = None,
        fallback_to_reactive: bool = True,
    ):
        """
        Args:
            queue_url: SQS queue URL to poll for actual depth observations
            aws_region: AWS region for SQS client
            config: PredictorConfig (defaults if None)
            fallback_to_reactive: if predictor not ready, use actual depth as metric
        """
        self.queue_url = queue_url
        self.fallback_to_reactive = fallback_to_reactive
        self.config = config or PredictorConfig()
        self.predictor = QueueDepthPredictor(self.config)
        self._actual_depth: int = 0
        self._sqs = boto3.client("sqs", region_name=aws_region)
        self._observation_thread: Optional[threading.Thread] = None
        self._running = False
        logger.info("PredictiveExternalScaler initialized", extra={
            "queue_url": queue_url,
            "horizon_minutes": self.config.horizon_minutes,
            "fallback_to_reactive": fallback_to_reactive,
        })

    # ── gRPC Method Implementations ───────────────────────────────────────────

    def IsActive(self, request: ScaledObjectRef) -> IsActiveResponse:
        """
        KEDA calls this every pollingInterval to check if scale-to-zero applies.

        Policy: active if predicted depth > 0 OR actual depth > 0.
        This prevents scale-to-zero when a traffic spike is predicted even if
        the queue is momentarily empty.
        """
        predicted = self._get_predicted_depth()
        is_active = (predicted > 0) or (self._actual_depth > 0)
        logger.debug("IsActive called", extra={
            "predicted_depth": predicted,
            "actual_depth": self._actual_depth,
            "result": is_active,
        })
        return IsActiveResponse(result=is_active)

    def GetMetricSpec(self, request: ScaledObjectRef) -> GetMetricSpecResponse:
        """
        KEDA calls this once to discover what metric this scaler provides.

        Returns:
            metricName: identifier for this custom metric
            targetSize: the per-pod target (mirrors KEDA targetQueueLength)
                       desiredReplicas = ceil(metricValue / targetSize)
        """
        return GetMetricSpecResponse(metric_specs=[{
            "metricName": self.METRIC_NAME,
            "targetSize": self.config.target_queue_length,
        }])

    def GetMetrics(self, request: ScaledObjectRef) -> GetMetricsResponse:
        """
        KEDA calls this every pollingInterval to get the current metric value.

        This is the KEY method:
          - If predictor ready + high confidence → return predicted_depth
          - If predictor not ready OR low confidence → return actual_depth (fallback)
          - KEDA computes: desiredReplicas = ceil(returned_value / targetSize)

        The beauty of this API: KEDA does NOT need to know whether the metric
        value came from a prediction or from the actual queue. It just uses the
        number to drive HPA — the intelligence is entirely in this method.
        """
        predicted = self._get_predicted_depth()
        metric_value = predicted

        logger.info("GetMetrics called", extra={
            "metric_name": self.METRIC_NAME,
            "metric_value": metric_value,
            "actual_depth": self._actual_depth,
            "predictor_ready": self.predictor.is_ready(),
        })

        return GetMetricsResponse(metric_values=[{
            "metricName": self.METRIC_NAME,
            "metricValue": int(math.ceil(metric_value)),
        }])

    # ── Internal: SQS Observation Loop ────────────────────────────────────────

    def start_observation_loop(self) -> None:
        """
        Start background thread that polls SQS depth every observation_interval_s.
        Call this before starting the gRPC server.
        """
        self._running = True
        self._observation_thread = threading.Thread(
            target=self._observation_loop,
            name="sqs-observer",
            daemon=True,
        )
        self._observation_thread.start()
        logger.info("SQS observation loop started")

    def stop(self) -> None:
        """Gracefully stop the observation loop."""
        self._running = False
        if self._observation_thread:
            self._observation_thread.join(timeout=10)
        logger.info("PredictiveExternalScaler stopped")

    def _observation_loop(self) -> None:
        """Poll SQS queue depth and feed observations to the predictor."""
        while self._running:
            try:
                response = self._sqs.get_queue_attributes(
                    QueueUrl=self.queue_url,
                    AttributeNames=["ApproximateNumberOfMessages"],
                )
                depth = int(
                    response["Attributes"].get("ApproximateNumberOfMessages", 0)
                )
                self._actual_depth = depth
                self.predictor.record_observation(depth=depth)

                logger.debug("SQS observation recorded", extra={
                    "depth": depth,
                    "predictor_ready": self.predictor.is_ready(),
                })
            except Exception as exc:
                logger.warning(f"SQS observation failed: {exc}")

            time.sleep(self.config.observation_interval_s)

    def _get_predicted_depth(self) -> float:
        """
        Get the predicted queue depth, with fallback logic.

        Returns:
            predicted_depth if predictor ready and confidence >= 0.5
            actual_depth if predictor not ready OR low confidence
        """
        if self.predictor.is_ready():
            result = self.predictor.predict()
            if result and result.confidence >= 0.5:
                return result.predicted_depth * self.config.prediction_buffer

        # Fallback: reactive (same as native KEDA SQS trigger)
        if self.fallback_to_reactive:
            return float(self._actual_depth)
        return 0.0

    def get_status(self) -> dict:
        """Return current status for health endpoint or logging."""
        return {
            "predictor": self.predictor.summary(),
            "actual_depth": self._actual_depth,
            "observation_loop_running": (
                self._observation_thread is not None
                and self._observation_thread.is_alive()
            ),
        }


# ─── Kubernetes Deployment Manifests (Documentation) ─────────────────────────

KEDA_EXTERNAL_SCALER_SCALEDOBJECT = """
# ── KEDA ScaledObject using External Scaler (replaces keda-scaled-object.yaml) ──
# Deploy when external scaler is running as a K8s Service in keda-demo namespace.
#
# Prerequisites:
#   1. Deploy external scaler as a Deployment:
#      kubectl apply -f manifests/external-scaler-deployment.yaml
#   2. Deploy external scaler Service (gRPC, port 50051):
#      kubectl apply -f manifests/external-scaler-service.yaml
#   3. Apply this ScaledObject (replaces the SQS-native one):
#      kubectl apply -f manifests/keda-external-scaledobject.yaml

apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: keda-demo-predictive-scaledobject
  namespace: keda-demo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: keda-demo

  pollingInterval:  15       # KEDA calls GetMetrics every 15 seconds
  cooldownPeriod:   300
  minReplicaCount:  0        # Allow scale-to-zero (IsActive controls this)
  maxReplicaCount:  5

  triggers:
    - type: external          # External scaler trigger
      metadata:
        scalerAddress: "predictive-scaler-service.keda-demo.svc.cluster.local:50051"
        # gRPC address of PredictiveExternalScaler server
"""

EXTERNAL_SCALER_DEPLOYMENT = """
# External Scaler Deployment manifest (future implementation)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: predictive-scaler
  namespace: keda-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: predictive-scaler
  template:
    metadata:
      labels:
        app: predictive-scaler
    spec:
      serviceAccountName: keda-demo  # Same IRSA role (needs sqs:GetQueueAttributes)
      containers:
        - name: scaler
          image: <ECR_URI>/predictive-scaler:latest
          ports:
            - containerPort: 50051
              name: grpc
          env:
            - name: SQS_QUEUE_URL
              valueFrom:
                configMapKeyRef:
                  name: keda-demo-config
                  key: SQS_QUEUE_URL
            - name: HORIZON_MINUTES
              value: "5"
"""

if __name__ == "__main__":
    """
    Demo: simulate 20 minutes of observations and show scaler behavior.
    Run: python ai/keda_external_scaler_stub.py
    """
    import math

    logging.basicConfig(level=logging.WARNING, format="%(message)s")

    print("\n🔌 KEDA External Scaler — Predictive Scaling Demo")
    print("=" * 60)
    print(f"{'Step':>5} {'Actual':>8} {'Predicted':>10} {'Metric':>8} {'IsActive':>10}")
    print("-" * 60)

    # Simulate without real SQS — manually feed observations
    cfg = PredictorConfig(min_observations=10, observation_interval_s=15)
    predictor = QueueDepthPredictor(cfg)

    for step in range(80):
        t = step * 15
        # Simulate traffic ramp: rises at t=5min, peaks at t=10min, falls
        depth = max(0, int(15 * math.sin(math.pi * t / 600) + 3 * math.sin(t / 30)))

        predictor.record_observation(depth=depth, timestamp=float(t))
        actual = depth

        if predictor.is_ready():
            result = predictor.predict()
            if result:
                predicted = round(result.predicted_depth, 1)
                buffered = int(math.ceil(predicted * cfg.prediction_buffer))
                is_active = (predicted > 0) or (actual > 0)
                print(f"{step:>5} {actual:>8} {predicted:>10} {buffered:>8} {str(is_active):>10}")
        elif step % 5 == 0:
            print(f"{step:>5} {actual:>8} {'warming...':>10} {actual:>8} {'warming...':>10}")

    print(f"\nFinal predictor status: {json.dumps(predictor.summary(), indent=2)}")
    print("\nKEDA ScaledObject YAML (External Scaler):")
    print(KEDA_EXTERNAL_SCALER_SCALEDOBJECT)
