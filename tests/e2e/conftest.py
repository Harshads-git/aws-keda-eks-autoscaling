"""
tests/e2e/conftest.py — Pytest Fixtures and Helpers for E2E Tests
================================================================

Provides shared fixtures, configuration, polling utilities, and Kubernetes /
HTTP clients for testing end-to-end autoscaling loops across the SmartScale AI
microservices ecosystem.

Can run against:
  1. Live Kubernetes / Kind cluster with port-forwards
  2. Local services directly
  3. CI pipeline with mocked network transport when live cluster is unavailable
"""

import json
import os
import time
import urllib.request
import urllib.error
from typing import Callable, Any, Dict, Optional
import pytest


# ─── Environment Configuration ────────────────────────────────────────────────

PRODUCER_API_URL = os.environ.get("PRODUCER_API_URL", "http://localhost:8091").rstrip("/")
PREDICTION_API_URL = os.environ.get("PREDICTION_API_URL", "http://localhost:8090").rstrip("/")
DASHBOARD_URL = os.environ.get("DASHBOARD_URL", "http://localhost:8092").rstrip("/")
E2E_NAMESPACE = os.environ.get("E2E_NAMESPACE", "keda-demo")
E2E_DEPLOYMENT = os.environ.get("E2E_DEPLOYMENT", "keda-demo")
E2E_TIMEOUT = int(os.environ.get("E2E_TIMEOUT", "90"))
E2E_POLL_INTERVAL = float(os.environ.get("E2E_POLL_INTERVAL", "2.0"))


# ─── Polling Helper ───────────────────────────────────────────────────────────

def poll_until(
    predicate: Callable[[], Any],
    timeout: float = E2E_TIMEOUT,
    interval: float = E2E_POLL_INTERVAL,
    desc: str = "condition",
) -> Any:
    """
    Repeatedly evaluates `predicate()` every `interval` seconds until it returns
    a truthy value or `timeout` expires.

    Returns the truthy value returned by `predicate()`.
    Raises TimeoutError on expiry.
    """
    deadline = time.monotonic() + timeout
    last_val = None
    while time.monotonic() < deadline:
        try:
            res = predicate()
            if res:
                return res
            last_val = res
        except Exception as e:
            last_val = f"Exception: {e}"
        time.sleep(interval)

    raise TimeoutError(
        f"Timed out after {timeout}s waiting for {desc}. Last evaluated state: {last_val}"
    )


# ─── Lightweight HTTP Client ──────────────────────────────────────────────────

class SimpleHTTPClient:
    """Lightweight HTTP helper using standard library urllib."""

    def __init__(self, base_url: str):
        self.base_url = base_url

    def get(self, path: str, timeout: float = 5.0) -> Dict[str, Any]:
        url = f"{self.base_url}/{path.lstrip('/')}"
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
                try:
                    data = json.loads(body)
                except Exception:
                    data = body
                return {"status": status, "data": data, "raw": body}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            return {"status": e.code, "error": str(e), "raw": body}
        except Exception as e:
            return {"status": 0, "error": str(e), "raw": ""}

    def post(self, path: str, payload: Dict[str, Any], timeout: float = 10.0) -> Dict[str, Any]:
        url = f"{self.base_url}/{path.lstrip('/')}"
        data_bytes = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data_bytes,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
                try:
                    data = json.loads(body)
                except Exception:
                    data = body
                return {"status": status, "data": data, "raw": body}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            return {"status": e.code, "error": str(e), "raw": body}
        except Exception as e:
            return {"status": 0, "error": str(e), "raw": ""}


# ─── Pytest Fixtures ──────────────────────────────────────────────────────────

@pytest.fixture(scope="session")
def producer_client() -> SimpleHTTPClient:
    """HTTP client targeting the Producer REST API."""
    return SimpleHTTPClient(PRODUCER_API_URL)


@pytest.fixture(scope="session")
def prediction_client() -> SimpleHTTPClient:
    """HTTP client targeting the Prediction REST API."""
    return SimpleHTTPClient(PREDICTION_API_URL)


@pytest.fixture(scope="session")
def dashboard_client() -> SimpleHTTPClient:
    """HTTP client targeting the Live Dashboard."""
    return SimpleHTTPClient(DASHBOARD_URL)


@pytest.fixture(scope="session")
def k8s_apps_api():
    """Returns an initialized Kubernetes AppsV1Api client, or None if unavailable."""
    try:
        from kubernetes import client as k8s_client, config as k8s_config
        try:
            k8s_config.load_incluster_config()
        except Exception:
            k8s_config.load_kube_config()
        return k8s_client.AppsV1Api()
    except Exception:
        return None


@pytest.fixture(scope="session")
def get_deployment_replicas(k8s_apps_api, dashboard_client):
    """
    Returns a callable `(namespace, name) -> dict` returning
    {'ready': int, 'desired': int}.
    Uses direct Kubernetes API if reachable, otherwise queries dashboard /api/stats.
    """
    def _fetch(namespace: str = E2E_NAMESPACE, name: str = E2E_DEPLOYMENT) -> Dict[str, int]:
        if k8s_apps_api:
            try:
                dep = k8s_apps_api.read_namespaced_deployment(name=name, namespace=namespace)
                return {
                    "ready": dep.status.ready_replicas or 0,
                    "desired": dep.spec.replicas or 0,
                }
            except Exception:
                pass

        # Fallback to dashboard API
        res = dashboard_client.get("/api/stats")
        if res.get("status") == 200 and isinstance(res.get("data"), dict):
            pods_info = res["data"].get("all_deployments", {}).get(name, {})
            if pods_info:
                return {
                    "ready": pods_info.get("ready", 0),
                    "desired": pods_info.get("desired", 0),
                }
            return {
                "ready": res["data"].get("pods_ready", 0),
                "desired": res["data"].get("pods_desired", 0),
            }

        return {"ready": 0, "desired": 0}

    return _fetch


@pytest.fixture
def wait_condition():
    """Provides the `poll_until` utility to test functions."""
    return poll_until
