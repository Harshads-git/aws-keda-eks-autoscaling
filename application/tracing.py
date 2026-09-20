"""
tracing.py — OpenTelemetry Distributed Tracing Setup for SmartScale AI
=============================================================================

Initializes the OpenTelemetry tracer with OTLP export and botocore
auto-instrumentation. Each SQS message gets a trace with this span hierarchy:

    smartscale.poll_cycle (root span)
    ├── aws.sqs.ReceiveMessage (auto-instrumented by botocore)
    ├── smartscale.process_message (custom span)
    │   ├── smartscale.parse_body
    │   ├── smartscale.business_logic
    │   └── smartscale.update_metrics
    └── aws.sqs.DeleteMessage (auto-instrumented by botocore)

Environment Variables:
    OTEL_ENABLED          : "true" to enable tracing (default: "false")
    OTEL_EXPORTER_ENDPOINT: gRPC endpoint (default: "http://localhost:4317")
    OTEL_SERVICE_NAME     : Service name in traces (default: "smartscale-consumer")

Usage:
    from tracing import init_tracer, get_tracer

    init_tracer()  # Call once at startup
    tracer = get_tracer()

    with tracer.start_as_current_span("my_operation") as span:
        span.set_attribute("message_id", "abc-123")
        # ... do work ...
"""

import os
import logging
from typing import Optional

logger = logging.getLogger("keda-demo")

# ─── Lazy imports: OpenTelemetry packages are optional ────────────────────────
# If OTel is not installed or OTEL_ENABLED != "true", we use a no-op tracer
# that creates dummy spans. This means tracing code never needs to be removed
# or guarded with if/else — it just silently does nothing.

_tracer = None
_initialized = False


def init_tracer() -> None:
    """
    Initialize the OpenTelemetry TracerProvider with OTLP gRPC exporter.

    Call this ONCE at application startup (before any spans are created).
    Safe to call multiple times — subsequent calls are no-ops.

    The TracerProvider is configured with:
      - Resource: identifies this service in the trace backend
      - BatchSpanProcessor: batches completed spans before export (efficient)
      - OTLPSpanExporter: sends spans via gRPC to the OTel Collector

    Why BatchSpanProcessor (not SimpleSpanProcessor):
      Simple: exports each span immediately (high overhead, good for debugging)
      Batch: buffers spans and exports in bulk every 5s (low overhead, for production)
    """
    global _tracer, _initialized

    if _initialized:
        return

    _initialized = True
    otel_enabled = os.environ.get("OTEL_ENABLED", "false").lower() == "true"

    if not otel_enabled:
        logger.info("OpenTelemetry tracing disabled (set OTEL_ENABLED=true to enable)")
        return

    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.resources import Resource, SERVICE_NAME
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor

        service_name = os.environ.get("OTEL_SERVICE_NAME", "smartscale-consumer")
        exporter_endpoint = os.environ.get("OTEL_EXPORTER_ENDPOINT", "http://localhost:4317")

        # Resource: metadata about this service instance
        # Shows up in Jaeger UI as the service name in the dropdown
        resource = Resource.create({
            SERVICE_NAME: service_name,
            "service.namespace": os.environ.get("POD_NAMESPACE", "keda-demo"),
            "service.instance.id": os.environ.get("POD_NAME", "unknown"),
            "deployment.environment": os.environ.get("ENVIRONMENT", "local"),
        })

        # TracerProvider: manages all tracers in the application
        provider = TracerProvider(resource=resource)

        # OTLP exporter: sends spans to the OpenTelemetry Collector
        exporter = OTLPSpanExporter(
            endpoint=exporter_endpoint,
            insecure=True,  # No TLS for local development
        )

        # BatchSpanProcessor: queues spans and exports in bulk
        # max_queue_size=2048: buffer up to 2048 spans before dropping
        # max_export_batch_size=512: send up to 512 spans per export
        # schedule_delay_millis=5000: export every 5 seconds
        processor = BatchSpanProcessor(
            exporter,
            max_queue_size=2048,
            max_export_batch_size=512,
            schedule_delay_millis=5000,
        )
        provider.add_span_processor(processor)

        # Set as the global TracerProvider
        trace.set_tracer_provider(provider)

        # Auto-instrument botocore (boto3 uses botocore under the hood)
        # After this call, every boto3 API call automatically gets a span:
        #   aws.sqs.ReceiveMessage, aws.sqs.DeleteMessage, etc.
        BotocoreInstrumentor().instrument()

        _tracer = trace.get_tracer("smartscale-ai", "1.0.0")

        logger.info(
            "OpenTelemetry tracing initialized",
            extra={
                "service_name": service_name,
                "exporter_endpoint": exporter_endpoint,
            },
        )

    except ImportError as e:
        logger.warning(
            "OpenTelemetry packages not installed, tracing disabled",
            extra={"error": str(e)},
        )
    except Exception as e:
        logger.error(
            "Failed to initialize OpenTelemetry tracing",
            extra={"error": str(e)},
        )


def get_tracer():
    """
    Get the application tracer instance.

    Returns:
        The OpenTelemetry tracer if enabled, otherwise a NoOpTracer
        that creates dummy spans (no overhead, no exports).

    Usage:
        tracer = get_tracer()
        with tracer.start_as_current_span("operation") as span:
            span.set_attribute("key", "value")
    """
    global _tracer

    if _tracer is not None:
        return _tracer

    # Return a no-op tracer if OTel is not initialized
    try:
        from opentelemetry import trace
        return trace.get_tracer("smartscale-ai-noop")
    except ImportError:
        return _NoOpTracer()


class _NoOpTracer:
    """
    Fallback tracer when OpenTelemetry is not installed.

    Provides the same interface as a real tracer but does nothing.
    This avoids littering the codebase with 'if tracing_enabled:' checks.
    """

    def start_as_current_span(self, name: str, **kwargs):
        return _NoOpSpan()

    def start_span(self, name: str, **kwargs):
        return _NoOpSpan()


class _NoOpSpan:
    """No-op span that supports the context manager protocol."""

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def set_attribute(self, key: str, value) -> None:
        pass

    def set_status(self, status) -> None:
        pass

    def record_exception(self, exception: Exception) -> None:
        pass

    def add_event(self, name: str, attributes: Optional[dict] = None) -> None:
        pass

    def end(self) -> None:
        pass
