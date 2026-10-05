"""
application/dashboard.py — Real-time SmartScale AI Web Dashboard
================================================================

FastAPI application serving an HTML dashboard that auto-refreshes
every 3 seconds using HTMX partial updates.

Why HTMX (not React/Vue/WebSockets)?
  HTMX is a lightweight (~14kb) JavaScript library that adds AJAX-style
  partial page updates via HTML attributes. No build toolchain, no npm,
  no JavaScript framework. The server renders HTML fragments and HTMX
  swaps them into the page.

  For a demo dashboard this is ideal:
  - Single Python file, no frontend build step
  - Works even on slow networks (only the changed fragment is sent)
  - Degrades gracefully if JavaScript is disabled (just shows static data)
  - Deployable as a static-feeling page despite being server-rendered

Dashboard panels (auto-refresh every 3s):
  ┌─────────────────────────────────────────────────┐
  │  SmartScale AI — Live Demo Dashboard            │
  ├────────────────┬────────────────┬───────────────┤
  │  Queue Depths  │  Pod Count     │  AI Predictor │
  │  Priority: 12  │  Running: 5    │  Mode: ARIMA  │
  │  Batch: 0      │  Pending: 0    │  Confidence:  │
  │  Total: 12     │  Target: 6     │  0.87         │
  ├────────────────┴────────────────┴───────────────┤
  │  Recent Messages (last 5 sent via producer API) │
  │  [index=49] [index=48] ... priority             │
  ├─────────────────────────────────────────────────┤
  │  KEDA Events (last 5 scale events)              │
  │  ScaleUp: 1→5 pods at 19:30:15                 │
  └─────────────────────────────────────────────────┘

Endpoints:
  GET /          → Full dashboard HTML page (with HTMX)
  GET /fragments/stats    → Stats panel HTML fragment (HTMX target)
  GET /fragments/events   → Events panel HTML fragment (HTMX target)
  GET /api/stats          → JSON stats (for external consumers / testing)
  GET /health             → Liveness probe
  GET /metrics            → Prometheus metrics

Data sources:
  Queue depth:   SQS GetQueueAttributes (via producer API /queue/depth or directly)
  Pod count:     Kubernetes API (in-cluster service account)
  AI predictor:  Prediction API GET /model/info
  Events:        In-memory ring buffer of scale events (populated by /api/event)
"""

import logging
import os
import sys
import time
import json
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

try:
    from fastapi import FastAPI, Request
    from fastapi.responses import HTMLResponse, PlainTextResponse
    from pydantic import BaseModel
    import uvicorn
    FASTAPI_AVAILABLE = True
except ImportError:
    FASTAPI_AVAILABLE = False

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from prometheus_client import Counter, Gauge, generate_latest, CONTENT_TYPE_LATEST
from pythonjsonlogger import jsonlogger

# ─── Logging ──────────────────────────────────────────────────────────────────

logger = logging.getLogger("dashboard")
logger.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(jsonlogger.JsonFormatter(
    "%(asctime)s %(name)s %(levelname)s %(message)s"
))
logger.addHandler(_handler)

# ─── Configuration ────────────────────────────────────────────────────────────

class DashboardConfig:
    priority_queue_url: str = os.environ.get("PRIORITY_QUEUE_URL", "")
    batch_queue_url: str = os.environ.get("BATCH_QUEUE_URL",
                          os.environ.get("SQS_QUEUE_URL", ""))
    prediction_api_url: str = os.environ.get(
        "PREDICTION_API_URL", "http://prediction-api.keda-demo.svc.cluster.local:8090"
    )
    producer_api_url: str = os.environ.get(
        "PRODUCER_API_URL", "http://producer-api.keda-demo.svc.cluster.local:8091"
    )
    namespace: str = os.environ.get("POD_NAMESPACE", "keda-demo")
    refresh_interval: int = int(os.environ.get("REFRESH_INTERVAL_SECONDS", "3"))
    aws_region: str = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    endpoint_url: Optional[str] = os.environ.get("AWS_ENDPOINT_URL") or None
    port: int = int(os.environ.get("DASHBOARD_PORT", "8092"))


_config = DashboardConfig()

# ─── Prometheus ───────────────────────────────────────────────────────────────

DASHBOARD_REQUESTS = Counter("dashboard_requests_total", "Total dashboard page requests")
DASHBOARD_ERRORS = Counter("dashboard_errors_total", "Total dashboard data fetch errors", ["source"])
QUEUE_DEPTH_GAUGE = Gauge("dashboard_queue_depth", "Queue depth as seen by dashboard", ["queue"])

# ─── In-memory event ring buffer ──────────────────────────────────────────────

_events: deque = deque(maxlen=20)  # Last 20 scale events

# ─── Global SQS client ────────────────────────────────────────────────────────

_sqs = None

def _init_sqs():
    global _sqs
    kwargs = dict(
        region_name=_config.aws_region,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "dummy"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "dummy"),
    )
    if _config.endpoint_url:
        kwargs["endpoint_url"] = _config.endpoint_url
    _sqs = boto3.client("sqs", **kwargs)

# ─── Data fetchers ────────────────────────────────────────────────────────────

def _get_queue_depth(queue_url: str, label: str) -> int:
    if not queue_url or not _sqs:
        return -1
    try:
        r = _sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        depth = int(r["Attributes"].get("ApproximateNumberOfMessages", 0))
        QUEUE_DEPTH_GAUGE.labels(queue=label).set(depth)
        return depth
    except Exception as e:
        DASHBOARD_ERRORS.labels(source="sqs").inc()
        return -1


def _get_pod_counts() -> dict:
    """Get pod counts from Kubernetes API (in-cluster)."""
    try:
        from kubernetes import client as k8s_client, config as k8s_config
        try:
            k8s_config.load_incluster_config()
        except Exception:
            k8s_config.load_kube_config()
        v1 = k8s_client.AppsV1Api()
        deployments = v1.list_namespaced_deployment(namespace=_config.namespace)
        pods = {}
        for d in deployments.items:
            pods[d.metadata.name] = {
                "ready": d.status.ready_replicas or 0,
                "desired": d.spec.replicas or 0,
            }
        return pods
    except Exception as e:
        DASHBOARD_ERRORS.labels(source="kubernetes").inc()
        return {}


def _get_predictor_info() -> dict:
    """Fetch predictor metadata from prediction-api /model/info."""
    try:
        import urllib.request
        url = f"{_config.prediction_api_url}/model/info"
        with urllib.request.urlopen(url, timeout=1) as resp:
            return json.loads(resp.read())
    except Exception:
        DASHBOARD_ERRORS.labels(source="prediction_api").inc()
        return {}


def _get_stats() -> dict:
    """Aggregate all dashboard data into one dict."""
    p_depth = _get_queue_depth(_config.priority_queue_url, "priority")
    b_depth = _get_queue_depth(_config.batch_queue_url, "batch")
    pods = _get_pod_counts()
    predictor = _get_predictor_info()

    # Find the main consumer deployment
    consumer = pods.get("keda-demo", {"ready": 0, "desired": 0})

    return {
        "priority_depth": p_depth,
        "batch_depth": b_depth,
        "total_depth": max(0, p_depth) + max(0, b_depth),
        "pods_ready": consumer["ready"],
        "pods_desired": consumer["desired"],
        "all_deployments": pods,
        "predictor": predictor,
        "events": list(_events)[-5:],  # Last 5
        "timestamp": datetime.now(timezone.utc).strftime("%H:%M:%S UTC"),
    }

# ─── HTML Templates ───────────────────────────────────────────────────────────

def _status_class(depth: int) -> str:
    if depth < 0:
        return "status-unknown"
    if depth == 0:
        return "status-ok"
    if depth < 10:
        return "status-warn"
    return "status-alert"


def _render_stats_fragment(stats: dict) -> str:
    p = stats["priority_depth"]
    b = stats["batch_depth"]
    ready = stats["pods_ready"]
    desired = stats["pods_desired"]
    pred = stats["predictor"]
    model_type = pred.get("model_type", "—")
    confidence = pred.get("last_confidence")
    conf_str = f"{confidence:.2f}" if confidence is not None else "—"
    ready_ok = "status-ok" if ready >= desired > 0 else "status-warn"

    return f"""
    <div class="stats-grid">
      <div class="stat-card {_status_class(p)}">
        <div class="stat-label">Priority Queue</div>
        <div class="stat-value">{p if p >= 0 else '?'}</div>
        <div class="stat-sub">messages</div>
      </div>
      <div class="stat-card {_status_class(b)}">
        <div class="stat-label">Batch Queue</div>
        <div class="stat-value">{b if b >= 0 else '?'}</div>
        <div class="stat-sub">messages</div>
      </div>
      <div class="stat-card {ready_ok}">
        <div class="stat-label">Consumer Pods</div>
        <div class="stat-value">{ready}<span class="stat-denom">/{desired}</span></div>
        <div class="stat-sub">ready / desired</div>
      </div>
      <div class="stat-card status-ok">
        <div class="stat-label">AI Predictor</div>
        <div class="stat-value">{model_type}</div>
        <div class="stat-sub">confidence: {conf_str}</div>
      </div>
    </div>
    <div class="updated-at">Updated {stats["timestamp"]}</div>
    """


def _render_events_fragment(stats: dict) -> str:
    events = stats["events"]
    if not events:
        return '<div class="no-events">No scale events yet. Send some messages!</div>'
    rows = ""
    for ev in reversed(events):
        rows += f"""
        <tr>
          <td class="ev-time">{ev.get("time", "—")}</td>
          <td class="ev-type ev-{ev.get('type','').lower()}">{ev.get('type','?')}</td>
          <td>{ev.get('from', '?')} → {ev.get('to', '?')} pods</td>
          <td class="ev-reason">{ev.get('reason','')}</td>
        </tr>"""
    return f"""
    <table class="events-table">
      <thead><tr>
        <th>Time</th><th>Event</th><th>Scale</th><th>Reason</th>
      </tr></thead>
      <tbody>{rows}</tbody>
    </table>"""


def _full_page(config: DashboardConfig) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SmartScale AI — Live Dashboard</title>
  <script src="https://unpkg.com/htmx.org@1.9.10"></script>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #0f172a; color: #e2e8f0; min-height: 100vh;
    }}
    header {{
      background: linear-gradient(135deg, #1e293b, #0f172a);
      border-bottom: 1px solid #334155;
      padding: 1rem 2rem;
      display: flex; align-items: center; gap: 1rem;
    }}
    header h1 {{ font-size: 1.4rem; font-weight: 700; color: #f1f5f9; }}
    header .badge {{
      background: #10b981; color: white;
      padding: 0.2rem 0.6rem; border-radius: 999px;
      font-size: 0.75rem; font-weight: 600;
      animation: pulse 2s infinite;
    }}
    @keyframes pulse {{ 0%,100%{{ opacity:1 }} 50%{{ opacity:0.6 }} }}
    main {{ padding: 1.5rem 2rem; }}
    h2 {{ font-size: 1rem; font-weight: 600; color: #94a3b8; text-transform: uppercase;
          letter-spacing: 0.05em; margin-bottom: 0.75rem; margin-top: 1.5rem; }}
    .stats-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 1rem;
    }}
    .stat-card {{
      background: #1e293b; border-radius: 0.75rem;
      padding: 1.25rem; border: 1px solid #334155;
      transition: border-color 0.3s;
    }}
    .stat-card.status-ok   {{ border-color: #10b981; }}
    .stat-card.status-warn {{ border-color: #f59e0b; }}
    .stat-card.status-alert{{ border-color: #ef4444; animation: pulse 1s infinite; }}
    .stat-card.status-unknown{{ border-color: #64748b; }}
    .stat-label {{ font-size: 0.8rem; color: #94a3b8; font-weight: 500; margin-bottom: 0.4rem; }}
    .stat-value {{ font-size: 2rem; font-weight: 700; color: #f1f5f9; line-height: 1; }}
    .stat-denom {{ font-size: 1rem; color: #64748b; }}
    .stat-sub   {{ font-size: 0.75rem; color: #64748b; margin-top: 0.25rem; }}
    .updated-at {{ font-size: 0.75rem; color: #475569; margin-top: 0.75rem; text-align: right; }}
    .events-table {{ width: 100%; border-collapse: collapse; }}
    .events-table th {{
      background: #1e293b; color: #94a3b8;
      font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
      padding: 0.5rem 0.75rem; text-align: left; border-bottom: 1px solid #334155;
    }}
    .events-table td {{ padding: 0.5rem 0.75rem; border-bottom: 1px solid #1e293b; font-size: 0.875rem; }}
    .events-table tr:hover td {{ background: #1e293b; }}
    .ev-time {{ color: #64748b; font-size: 0.8rem; }}
    .ev-scaleup   {{ color: #10b981; font-weight: 600; }}
    .ev-scaledown {{ color: #f59e0b; font-weight: 600; }}
    .ev-reason    {{ color: #94a3b8; font-size: 0.8rem; }}
    .no-events {{ color: #475569; font-style: italic; padding: 1rem 0; }}
    .demo-bar {{
      background: #1e293b; border: 1px solid #334155; border-radius: 0.75rem;
      padding: 1rem 1.5rem; display: flex; gap: 1rem; align-items: center;
      flex-wrap: wrap;
    }}
    .demo-bar label {{ font-size: 0.875rem; color: #94a3b8; }}
    .demo-bar input[type=number] {{
      background: #0f172a; border: 1px solid #334155; color: #f1f5f9;
      padding: 0.4rem 0.75rem; border-radius: 0.5rem; width: 80px; font-size: 0.875rem;
    }}
    .demo-bar select {{
      background: #0f172a; border: 1px solid #334155; color: #f1f5f9;
      padding: 0.4rem 0.75rem; border-radius: 0.5rem; font-size: 0.875rem;
    }}
    .btn-send {{
      background: #6366f1; color: white; border: none; border-radius: 0.5rem;
      padding: 0.5rem 1.25rem; font-size: 0.875rem; font-weight: 600;
      cursor: pointer; transition: background 0.2s;
    }}
    .btn-send:hover {{ background: #4f46e5; }}
    #send-result {{ font-size: 0.8rem; color: #10b981; }}
  </style>
</head>
<body>
  <header>
    <h1>⚡ SmartScale AI</h1>
    <span class="badge">LIVE</span>
    <span style="color:#64748b;font-size:0.85rem;margin-left:auto">
      Refreshing every {config.refresh_interval}s via HTMX
    </span>
  </header>

  <main>
    <!-- Stats panel: auto-refreshes via HTMX -->
    <h2>Queue Depths &amp; Pod Status</h2>
    <div
      id="stats"
      hx-get="/fragments/stats"
      hx-trigger="load, every {config.refresh_interval}s"
      hx-swap="innerHTML"
    >
      <div style="color:#64748b;padding:1rem">Loading stats...</div>
    </div>

    <!-- Demo trigger form: sends to producer API via HTMX POST -->
    <h2>Demo Trigger</h2>
    <div class="demo-bar">
      <label>Messages:</label>
      <input type="number" id="msg-count" value="20" min="1" max="500">
      <label>Queue:</label>
      <select id="msg-queue">
        <option value="priority">Priority</option>
        <option value="batch">Batch</option>
      </select>
      <button
        class="btn-send"
        hx-post="/api/send-bulk"
        hx-include="#msg-count, #msg-queue"
        hx-target="#send-result"
        hx-swap="innerHTML"
      >Send Messages</button>
      <span id="send-result"></span>
    </div>

    <!-- Events panel: auto-refreshes -->
    <h2>Scale Events</h2>
    <div
      id="events"
      hx-get="/fragments/events"
      hx-trigger="load, every {config.refresh_interval}s"
      hx-swap="innerHTML"
    >
      <div style="color:#64748b;padding:1rem">Loading events...</div>
    </div>
  </main>
</body>
</html>"""

# ─── Application factory ──────────────────────────────────────────────────────

def create_app() -> "FastAPI":

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        _init_sqs()
        logger.info("Dashboard started", extra={"port": _config.port})
        yield

    app = FastAPI(title="SmartScale AI Dashboard", lifespan=lifespan)

    @app.get("/", response_class=HTMLResponse)
    async def index():
        DASHBOARD_REQUESTS.inc()
        return _full_page(_config)

    @app.get("/fragments/stats", response_class=HTMLResponse)
    async def stats_fragment():
        stats = _get_stats()
        return _render_stats_fragment(stats)

    @app.get("/fragments/events", response_class=HTMLResponse)
    async def events_fragment():
        stats = _get_stats()
        return _render_events_fragment(stats)

    @app.get("/api/stats")
    async def api_stats():
        return _get_stats()

    @app.post("/api/event")
    async def record_event(event_type: str, from_pods: int, to_pods: int, reason: str = ""):
        """Record a KEDA scale event (called by monitoring scripts)."""
        _events.append({
            "time": datetime.now(timezone.utc).strftime("%H:%M:%S"),
            "type": event_type,
            "from": from_pods,
            "to": to_pods,
            "reason": reason,
        })
        return {"status": "recorded"}

    @app.post("/api/send-bulk", response_class=HTMLResponse)
    async def send_bulk_htmx(request: Request):
        """HTMX endpoint: proxies to producer API and returns HTML result."""
        form = await request.form()
        count = int(form.get("msg-count", 10))
        queue_type = form.get("msg-queue", "priority")
        try:
            import urllib.request
            import urllib.parse
            payload = json.dumps({"count": count, "queue_type": queue_type}).encode()
            req = urllib.request.Request(
                f"{_config.producer_api_url}/send/bulk",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                return f'✅ Sent {data["sent"]} messages to {queue_type} queue'
        except Exception as e:
            DASHBOARD_ERRORS.labels(source="producer_api").inc()
            return f'❌ Error: {e}'

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/metrics")
    async def metrics():
        return PlainTextResponse(
            generate_latest().decode("utf-8"),
            media_type=CONTENT_TYPE_LATEST,
        )

    return app


if __name__ == "__main__":
    if not FASTAPI_AVAILABLE:
        sys.exit(1)
    app = create_app()
    uvicorn.run(app, host="0.0.0.0", port=_config.port, log_level="warning")
