"""
Service A  -  the public-facing entrypoint (port 3001).

Responsibilities (from the assignment):
  - expose a health endpoint
  - accept incoming requests from users (via Nginx)
  - initiate communication with Service B
  - receive callbacks from Service C
  - log everything as structured JSON

This is the ONLY service Nginx will proxy to. B and C sit behind it.
"""

import os
import sys
import time
import uuid

import requests
from flask import Flask, request, jsonify

# Make the shared `common` package importable regardless of where
# the process is started from.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common.logging_setup import get_logger, log_event  # noqa: E402

SERVICE_NAME = "service-a"

# --- Configuration via environment variables ---------------------------------
# Nothing is hardcoded: ports and downstream addresses come from the
# environment so the same code runs in dev and under systemd unchanged.
# Downstream services are referenced by NAME, never by IP (service discovery).
BIND_HOST = os.getenv("BIND_HOST", "127.0.0.1")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "3001"))
SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://service-b.internal:3002")
DOWNSTREAM_TIMEOUT = float(os.getenv("DOWNSTREAM_TIMEOUT", "5"))

REQUEST_ID_HEADER = "X-Request-ID"

log = get_logger(SERVICE_NAME)
app = Flask(__name__)


def request_id_from(req) -> str:
    """Reuse the incoming trace id, or mint a new one if this is the front door."""
    return req.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())


@app.get("/health")
def health():
    """Liveness probe. systemd and humans both use this to confirm A is up."""
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried", request_id=rid,
              path="/health", outcome="ok")
    return jsonify(status="ok", service=SERVICE_NAME), 200


@app.post("/process")
def process():
    """
    Main entrypoint. Flow:
        client -> (A) -> B -> C -> callback to A
    A starts the chain by calling B, then returns B's result to the caller.
    """
    rid = request_id_from(request)
    started = time.time()

    log_event(log, "request_received", "request received from client",
              request_id=rid, method="POST", path="/process",
              upstream=request.remote_addr)

    try:
        log_event(log, "calling_service_b", "forwarding request to Service B",
                  request_id=rid, target=SERVICE_B_URL)

        resp = requests.post(
            f"{SERVICE_B_URL}/process",
            json={"origin": SERVICE_NAME},
            headers={REQUEST_ID_HEADER: rid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        resp.raise_for_status()

        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "request_completed", "request finished successfully",
                  request_id=rid, status=200, outcome="success",
                  duration_ms=duration_ms)

        return jsonify(
            service=SERVICE_NAME,
            request_id=rid,
            outcome="success",
            downstream=resp.json(),
        ), 200

    except requests.exceptions.RequestException as exc:
        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "downstream_error",
                  f"failed talking to Service B: {exc}",
                  request_id=rid, target=SERVICE_B_URL,
                  outcome="failure", status=502, duration_ms=duration_ms,
                  level=40)  # ERROR
        return jsonify(
            service=SERVICE_NAME,
            request_id=rid,
            outcome="failure",
            error="downstream service unavailable",
        ), 502


@app.post("/callback")
def callback():
    """
    Service C calls this when it has finished processing. This proves the
    full round trip (A -> B -> C -> A) and is logged under the SAME request id.
    """
    rid = request_id_from(request)
    payload = request.get_json(silent=True) or {}
    log_event(log, "callback_received", "callback received from Service C",
              request_id=rid, path="/callback", source="service-c",
              detail=payload, outcome="ok")
    return jsonify(status="acknowledged", service=SERVICE_NAME,
                   request_id=rid), 200


@app.errorhandler(404)
def not_found(_err):
    """Invalid endpoints must return a proper response AND be logged."""
    rid = request_id_from(request)
    log_event(log, "not_found", "request to unknown endpoint",
              request_id=rid, method=request.method, path=request.path,
              status=404, outcome="rejected", level=30)  # WARNING
    return jsonify(service=SERVICE_NAME, request_id=rid,
                   error="not found", path=request.path), 404


@app.errorhandler(500)
def server_error(_err):
    rid = request_id_from(request)
    log_event(log, "internal_error", "unhandled server error",
              request_id=rid, path=request.path, status=500,
              outcome="error", level=40)  # ERROR
    return jsonify(service=SERVICE_NAME, request_id=rid,
                   error="internal server error"), 500


if __name__ == "__main__":
    log_event(log, "service_starting",
              f"{SERVICE_NAME} starting on {BIND_HOST}:{SERVICE_PORT}",
              bind=BIND_HOST, port=SERVICE_PORT, downstream=SERVICE_B_URL)
    app.run(host=BIND_HOST, port=SERVICE_PORT, threaded=True)
