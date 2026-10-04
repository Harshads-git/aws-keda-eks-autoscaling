"""
application/producer_api.py — SQS Message Producer REST API
=============================================================

FastAPI server that accepts HTTP requests and sends messages to SQS queues.
Serves as the "front door" for the SmartScale AI demo — everything that feeds
the KEDA-scaled consumers flows through this API.

Why a Producer API?
  The demo needs a way to inject messages into SQS from outside the cluster.
  Options:
    1. aws sqs send-message CLI → requires AWS CLI, no rate control
    2. send_local_messages.py   → good for scripts, no REST interface
    3. THIS: FastAPI producer    → REST interface, usable from curl/Postman/
                                   load testing tools (k6, Locust, Vegeta)

Integration with Multi-Queue Consumer (Day 39):
  POST /send           → sends to PRIORITY queue (fast, low latency SLO)
  POST /send/batch     → sends to BATCH queue (slow, throughput optimised)
  POST /send/bulk      → sends N messages, triggers KEDA autoscale demo

Integration with KEDA Autoscaling:
  Each message sent increments ApproximateNumberOfMessages in SQS.
  KEDA polls this metric and scales pods accordingly.
  The /send/bulk endpoint is the primary demo trigger:
    POST /send/bulk {"count": 50, "queue_type": "priority"}
    → 50 messages in priority queue
    → KEDA: ceil(50/2) = 25 pods → capped at maxReplicaCount=10
    → Watch: kubectl get pods -n keda-demo -w

Endpoints:
  POST /send              → Send a single message to priority or batch queue
  POST /send/bulk         → Send N messages (demo trigger)
  GET  /queue/depth       → Current depth of both queues
  GET  /health            → Liveness probe
  GET  /metrics           → Prometheus metrics

Environment Variables:
  PRIORITY_QUEUE_URL:  SQS URL for priority queue
  BATCH_QUEUE_URL:     SQS URL for batch queue
  SQS_QUEUE_URL:       Fallback single-queue URL
  AWS_ENDPOINT_URL:    Override for local ElasticMQ
  API_PORT:            Bind port (default: 8091)
"""

import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager
from typing import List, Optional

try:
    from fastapi import FastAPI, HTTPException, BackgroundTasks
    from fastapi.responses import PlainTextResponse
    from pydantic import BaseModel, Field, field_validator
    import uvicorn
    FASTAPI_AVAILABLE = True
except ImportError:
    FASTAPI_AVAILABLE = False

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST
from pythonjsonlogger import jsonlogger

# ─── Logging ──────────────────────────────────────────────────────────────────

def _setup_logging() -> logging.Logger:
    logger = logging.getLogger("producer-api")
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

MESSAGES_SENT = Counter(
    "producer_messages_sent_total",
    "Total messages sent to SQS",
    ["queue_type"],
)
MESSAGES_FAILED = Counter(
    "producer_messages_failed_total",
    "Total messages that failed to send",
    ["queue_type"],
)
SEND_LATENCY = Histogram(
    "producer_send_latency_seconds",
    "Time to send a single message to SQS",
    ["queue_type"],
    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0],
)
BULK_SEND_SIZE = Histogram(
    "producer_bulk_send_size",
    "Number of messages per bulk send request",
    buckets=[1, 5, 10, 25, 50, 100, 500],
)
PRIORITY_QUEUE_DEPTH = Gauge(
    "producer_priority_queue_depth",
    "ApproximateNumberOfMessages in priority queue",
)
BATCH_QUEUE_DEPTH = Gauge(
    "producer_batch_queue_depth",
    "ApproximateNumberOfMessages in batch queue",
)

# ─── Configuration ────────────────────────────────────────────────────────────

class ProducerConfig:
    base_url = os.environ.get("SQS_QUEUE_URL", "")
    priority_queue_url: str = os.environ.get(
        "PRIORITY_QUEUE_URL",
        base_url + "-priority" if base_url else "",
    )
    batch_queue_url: str = os.environ.get(
        "BATCH_QUEUE_URL",
        base_url + "-batch" if base_url else base_url,
    )
    aws_region: str = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    endpoint_url: Optional[str] = os.environ.get("AWS_ENDPOINT_URL") or None
    port: int = int(os.environ.get("API_PORT", "8091"))


# ─── Global SQS client ────────────────────────────────────────────────────────

_sqs = None
_config = ProducerConfig()


def _init_sqs():
    global _sqs
    kwargs = {
        "region_name": _config.aws_region,
        "aws_access_key_id": os.environ.get("AWS_ACCESS_KEY_ID", "dummy"),
        "aws_secret_access_key": os.environ.get("AWS_SECRET_ACCESS_KEY", "dummy"),
    }
    if _config.endpoint_url:
        kwargs["endpoint_url"] = _config.endpoint_url
    _sqs = boto3.client("sqs", **kwargs)
    logger.info("SQS client initialised", extra={
        "endpoint": _config.endpoint_url,
        "priority_queue": _config.priority_queue_url,
        "batch_queue": _config.batch_queue_url,
    })


# ─── Pydantic models ──────────────────────────────────────────────────────────

class SendRequest(BaseModel):
    body: str = Field(..., description="Message body (any string or JSON string)")
    queue_type: str = Field("priority", description="'priority' or 'batch'")
    message_id: Optional[str] = Field(None, description="Optional idempotency key")
    attributes: Optional[dict] = Field(None, description="Custom SQS message attributes")

    @field_validator("queue_type")
    @classmethod
    def validate_queue_type(cls, v):
        if v not in ("priority", "batch"):
            raise ValueError("queue_type must be 'priority' or 'batch'")
        return v


class BulkSendRequest(BaseModel):
    count: int = Field(..., ge=1, le=500, description="Number of messages to send (1-500)")
    queue_type: str = Field("priority", description="'priority' or 'batch'")
    body_template: str = Field(
        '{"event": "demo", "index": {index}}',
        description="Message body template. Use {index} as placeholder.",
    )

    @field_validator("queue_type")
    @classmethod
    def validate_queue_type(cls, v):
        if v not in ("priority", "batch"):
            raise ValueError("queue_type must be 'priority' or 'batch'")
        return v


class SendResponse(BaseModel):
    message_id: str
    queue_type: str
    queue_url: str
    send_duration_ms: float


class BulkSendResponse(BaseModel):
    sent: int
    failed: int
    queue_type: str
    total_duration_ms: float


class QueueDepthResponse(BaseModel):
    priority_queue_depth: int
    batch_queue_depth: int
    total_depth: int
    priority_queue_url: str
    batch_queue_url: str


# ─── Helper functions ─────────────────────────────────────────────────────────

def _get_queue_url(queue_type: str) -> str:
    if queue_type == "priority":
        url = _config.priority_queue_url
    else:
        url = _config.batch_queue_url
    if not url:
        raise HTTPException(
            status_code=503,
            detail=f"{queue_type} queue URL not configured. Set PRIORITY_QUEUE_URL or BATCH_QUEUE_URL.",
        )
    return url


def _send_one(body: str, queue_url: str, queue_type: str, dedup_id: Optional[str] = None) -> str:
    """Send a single message. Returns MessageId."""
    start = time.monotonic()
    try:
        kwargs = {
            "QueueUrl": queue_url,
            "MessageBody": body,
        }
        if dedup_id:
            kwargs["MessageDeduplicationId"] = dedup_id
        response = _sqs.send_message(**kwargs)
        duration = time.monotonic() - start
        MESSAGES_SENT.labels(queue_type=queue_type).inc()
        SEND_LATENCY.labels(queue_type=queue_type).observe(duration)
        return response["MessageId"]
    except (BotoCoreError, ClientError) as e:
        duration = time.monotonic() - start
        MESSAGES_FAILED.labels(queue_type=queue_type).inc()
        raise HTTPException(status_code=503, detail=f"SQS send failed: {e}")


def _get_queue_depth(queue_url: str) -> int:
    """Get ApproximateNumberOfMessages for a queue."""
    try:
        response = _sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        return int(response["Attributes"].get("ApproximateNumberOfMessages", 0))
    except Exception:
        return -1


# ─── Application factory ──────────────────────────────────────────────────────

def create_app() -> "FastAPI":

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        _init_sqs()
        logger.info("Producer API started", extra={"port": _config.port})
        yield
        logger.info("Producer API shutting down")

    app = FastAPI(
        title="SmartScale AI — Message Producer API",
        description="Sends SQS messages to trigger KEDA autoscaling demos.",
        version="1.0.0",
        lifespan=lifespan,
    )

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.post("/send", response_model=SendResponse)
    async def send_message(req: SendRequest):
        """Send a single message to the priority or batch queue."""
        queue_url = _get_queue_url(req.queue_type)
        msg_id = req.message_id or str(uuid.uuid4())
        start = time.monotonic()
        sqs_msg_id = _send_one(req.body, queue_url, req.queue_type, msg_id)
        duration_ms = (time.monotonic() - start) * 1000
        logger.info("Message sent", extra={
            "queue_type": req.queue_type,
            "message_id": sqs_msg_id,
            "duration_ms": round(duration_ms, 2),
        })
        return SendResponse(
            message_id=sqs_msg_id,
            queue_type=req.queue_type,
            queue_url=queue_url,
            send_duration_ms=round(duration_ms, 2),
        )

    @app.post("/send/bulk", response_model=BulkSendResponse)
    async def send_bulk(req: BulkSendRequest):
        """
        Send N messages to trigger KEDA autoscaling.

        Demo usage:
          curl -X POST http://localhost:8091/send/bulk \\
            -H 'Content-Type: application/json' \\
            -d '{"count": 50, "queue_type": "priority"}'

        After this: kubectl get pods -n keda-demo -w
        """
        queue_url = _get_queue_url(req.queue_type)
        sent = 0
        failed = 0
        start = time.monotonic()

        # SQS supports sending up to 10 messages in a single batch request
        BATCH_SIZE = 10
        for batch_start in range(0, req.count, BATCH_SIZE):
            batch_end = min(batch_start + BATCH_SIZE, req.count)
            entries = []
            for i in range(batch_start, batch_end):
                body = req.body_template.replace("{index}", str(i))
                entries.append({
                    "Id": str(i % BATCH_SIZE),   # ID within this batch (0-9)
                    "MessageBody": body,
                })

            try:
                response = _sqs.send_message_batch(
                    QueueUrl=queue_url,
                    Entries=entries,
                )
                batch_sent = len(response.get("Successful", []))
                batch_failed = len(response.get("Failed", []))
                sent += batch_sent
                failed += batch_failed
                MESSAGES_SENT.labels(queue_type=req.queue_type).inc(batch_sent)
                if batch_failed:
                    MESSAGES_FAILED.labels(queue_type=req.queue_type).inc(batch_failed)
            except (BotoCoreError, ClientError) as e:
                failed += (batch_end - batch_start)
                logger.error("Batch send failed", extra={"error": str(e), "batch_start": batch_start})

        total_ms = (time.monotonic() - start) * 1000
        BULK_SEND_SIZE.observe(req.count)

        logger.info("Bulk send complete", extra={
            "queue_type": req.queue_type,
            "sent": sent,
            "failed": failed,
            "total_ms": round(total_ms, 1),
        })
        return BulkSendResponse(
            sent=sent,
            failed=failed,
            queue_type=req.queue_type,
            total_duration_ms=round(total_ms, 1),
        )

    @app.get("/queue/depth", response_model=QueueDepthResponse)
    async def queue_depth():
        """Get current depth of both queues (for monitoring)."""
        p_depth = _get_queue_depth(_config.priority_queue_url)
        b_depth = _get_queue_depth(_config.batch_queue_url)
        PRIORITY_QUEUE_DEPTH.set(max(0, p_depth))
        BATCH_QUEUE_DEPTH.set(max(0, b_depth))
        return QueueDepthResponse(
            priority_queue_depth=p_depth,
            batch_queue_depth=b_depth,
            total_depth=max(0, p_depth) + max(0, b_depth),
            priority_queue_url=_config.priority_queue_url,
            batch_queue_url=_config.batch_queue_url,
        )

    @app.get("/metrics")
    async def metrics():
        return PlainTextResponse(
            generate_latest().decode("utf-8"),
            media_type=CONTENT_TYPE_LATEST,
        )

    return app


# ─── Entrypoint ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not FASTAPI_AVAILABLE:
        logger.error("FastAPI/uvicorn not installed. Run: pip install fastapi uvicorn")
        sys.exit(1)
    app = create_app()
    uvicorn.run(app, host="0.0.0.0", port=_config.port, log_level="warning")
