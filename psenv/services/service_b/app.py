"""
Service B  -  internal service (port 3002).

Responsibilities:
  - expose a health endpoint
  - receive requests from Service A
  - forward requests to Service C
  - log everything as structured JSON

B is internal infrastructure: it binds to loopback and is never proxied
by Nginx, so it cannot be reached from outside the VM.
"""

import os
import sys
import time
import uuid

import requests
from flask import Flask, request, jsonify

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common.logging_setup import get_logger, log_event  # noqa: E402

SERVICE_NAME = "service-b"

BIND_HOST = os.getenv("BIND_HOST", "127.0.0.1")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "3002"))
SERVICE_C_URL = os.getenv("SERVICE_C_URL", "http://service-c.internal:3003")
DOWNSTREAM_TIMEOUT = float(os.getenv("DOWNSTREAM_TIMEOUT", "5"))

REQUEST_ID_HEADER = "X-Request-ID"

log = get_logger(SERVICE_NAME)
app = Flask(__name__)


def request_id_from(req) -> str:
    return req.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())


@app.get("/health")
def health():
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried", request_id=rid,
              path="/health", outcome="ok")
    return jsonify(status="ok", service=SERVICE_NAME), 200


@app.post("/process")
def process():
    rid = request_id_from(request)
    started = time.time()

    log_event(log, "request_received", "request received from Service A",
              request_id=rid, method="POST", path="/process",
              upstream=request.remote_addr)

    try:
        log_event(log, "calling_service_c", "forwarding request to Service C",
                  request_id=rid, target=SERVICE_C_URL)

        resp = requests.post(
            f"{SERVICE_C_URL}/process",
            json={"origin": SERVICE_NAME},
            headers={REQUEST_ID_HEADER: rid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        resp.raise_for_status()

        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "request_completed", "forwarded and got response from C",
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
                  f"failed talking to Service C: {exc}",
                  request_id=rid, target=SERVICE_C_URL,
                  outcome="failure", status=502, duration_ms=duration_ms,
                  level=40)
        return jsonify(
            service=SERVICE_NAME,
            request_id=rid,
            outcome="failure",
            error="downstream service unavailable",
        ), 502


@app.errorhandler(404)
def not_found(_err):
    rid = request_id_from(request)
    log_event(log, "not_found", "request to unknown endpoint",
              request_id=rid, method=request.method, path=request.path,
              status=404, outcome="rejected", level=30)
    return jsonify(service=SERVICE_NAME, request_id=rid,
                   error="not found", path=request.path), 404


@app.errorhandler(500)
def server_error(_err):
    rid = request_id_from(request)
    log_event(log, "internal_error", "unhandled server error",
              request_id=rid, path=request.path, status=500,
              outcome="error", level=40)
    return jsonify(service=SERVICE_NAME, request_id=rid,
                   error="internal server error"), 500


if __name__ == "__main__":
    log_event(log, "service_starting",
              f"{SERVICE_NAME} starting on {BIND_HOST}:{SERVICE_PORT}",
              bind=BIND_HOST, port=SERVICE_PORT, downstream=SERVICE_C_URL)
    app.run(host=BIND_HOST, port=SERVICE_PORT, threaded=True)
