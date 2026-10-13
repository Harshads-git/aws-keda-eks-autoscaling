# ADR 0003: HTMX-Driven Real-Time Dashboard over SPA Frameworks

* **Status:** Accepted
* **Date:** 2026-10-13
* **Deciders:** Full-Stack Architecture & DevOps Team
* **Consulted:** SRE, Frontend Engineering

---

## 1. Context & Problem Statement

To provide operators, engineers, and demo evaluators with visibility into the autoscaling system, SmartScale AI requires a lightweight, live web dashboard displaying:
1. Live queue depths (priority and batch queues)
2. Real-time consumer pod readiness and desired replica counts from Kubernetes
3. Predictive AI model state and confidence metrics
4. A demo load injection trigger form
5. Chronological stream of KEDA scaling events

Traditional modern web architectures standardly default to Single Page Applications (SPAs) built with React, Vue, or Angular, communicating with a backend API via REST or WebSockets.

However, introducing an SPA into a Kubernetes platform repository creates significant complexity:
* Requires a Node.js/npm build pipeline alongside Python container builds.
* Dramatically inflates CI build times and container image sizes.
* Requires managing state synchronization, client-side routers, and build artifact hosting.
* Introduces stateful connection management and proxy buffering issues if using WebSockets across Kubernetes ingress controllers.

We need a minimalist, highly reliable dashboard architecture that requires **zero frontend build steps** while providing dynamic, real-time UI updates.

---

## 2. Decision Drivers

* **Zero Build Pipeline Overhead:** No Node.js, Webpack, Vite, or npm dependencies in the repository.
* **Single Container Deployment:** Packaged and deployed entirely within a lightweight Python container.
* **Low Latency Dynamic Refresh:** Seamless updates every 2–3 seconds without full-page reloads.
* **Standard HTTP Compatibility:** Use plain HTTP GET/POST without persistent WebSocket connection state.
* **Graceful Degradation:** Resilient to transient disconnections and low-bandwidth environments.

---

## 3. Considered Options

* **Option 1: React / Vite Single Page Application (SPA)**
* **Option 2: WebSocket Streaming with Vanilla JavaScript**
* **Option 3: Server-Rendered HTML with HTMX Partial Swapping**

---

## 4. Evaluation of Options

### Option 1: React / Vite SPA
* **Pros:** Rich ecosystem; granular component reactivity.
* **Cons:** Requires Node.js in CI/CD; doubles container build time; adds frontend dependencies and bundle management; excessive complexity for an operations monitoring tool.

### Option 2: WebSocket Streaming with Vanilla JS
* **Pros:** True server-push event delivery; no external libraries.
* **Cons:** Stateful connections require heartbeat/reconnection logic; prone to disconnections through AWS ALB / Kubernetes Ingress timeouts; complicates load balancing.

### Option 3: Server-Rendered HTML with HTMX
* **Pros:**
  * **~14KB footprint:** Single script tag loaded from CDN.
  * **Zero build step:** Everything is authored in standard Python files (`application/dashboard.py`).
  * **Declarative HTML attributes:** Partial updates configured via `hx-get="/fragments/stats"` and `hx-trigger="every 3s"`.
  * **Stateless HTTP:** Standard GET/POST requests work reliably through any reverse proxy, ingress, or port-forward.
  * **Low server overhead:** Server only renders and transmits lightweight HTML fragments.
* **Cons:** Relies on client polling rather than sub-millisecond push (polling every 3s is more than adequate for queue autoscaling monitoring).

---

## 5. Decision Outcome

**Chosen Option:** **Option 3: Server-Rendered HTML with HTMX**

We implemented the live dashboard in `application/dashboard.py` using FastAPI and HTMX.

### Architecture Flow

```
[ Browser Client ]
        │
        │ 1. GET / (Initial Load)
        ▼
[ FastAPI Dashboard ] ──▶ Returns full HTML + htmx.org CDN script
        │
        │ 2. Periodic Poll: GET /fragments/stats (every 3s)
        ▼
[ Server-Side Aggregator ]
        ├── SQS Client (GetQueueAttributes)
        ├── K8s API Client (read_namespaced_deployment)
        └── Prediction API (/model/info)
        │
        ▼ Returns HTML Fragment: <div class="stats-grid">...</div>
[ HTMX Engine in Browser ] ──▶ Swaps #stats innerHTML without page flicker
```

---

## 6. Consequences & Operational Mitigations

### Positive Consequences
* **Single Language Codebase:** 100% Python backend and UI logic; zero JavaScript build tools in git repository.
* **Instant Deployment:** Container build takes under 15 seconds.
* **Zero Client Dependency Drift:** No `node_modules` security vulnerabilities or CVE maintenance overhead.
* **Port-Forward Ready:** Operates seamlessly via `kubectl port-forward svc/dashboard 8092:8092`.

### Negative Consequences & Mitigations
* **Polling Overhead on Backend:** Repeated queries every 3 seconds to SQS and Kubernetes API.
  * *Mitigation:* The dashboard uses lightweight in-memory caching and ConfigMap controls (`REFRESH_INTERVAL_SECONDS=3`) that can be scaled up to 10s if cluster resource conservation is required.
