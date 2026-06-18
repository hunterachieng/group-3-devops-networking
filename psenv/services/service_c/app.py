"""
Service C  -  internal service (port 3003).

Responsibilities:
  - expose a health endpoint
  - receive requests from Service B
  - notify Service A when processing is complete (the callback)
  - log everything as structured JSON

Like B, C is internal: loopback-bound and never proxied by Nginx.
"""

import os
import sys
import time
import uuid

import requests
from flask import Flask, request, jsonify

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common.logging_setup import get_logger, log_event  # noqa: E402

SERVICE_NAME = "service-c"

BIND_HOST = os.getenv("BIND_HOST", "127.0.0.1")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "3003"))
# C notifies A, so it needs to know where A lives - again, by name.
SERVICE_A_URL = os.getenv("SERVICE_A_URL", "http://service-a.internal:3001")
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

    log_event(log, "request_received", "request received from Service B",
              request_id=rid, method="POST", path="/process",
              upstream=request.remote_addr)

    # Pretend to do meaningful work here.
    log_event(log, "processing", "performing work", request_id=rid)
    time.sleep(0.05)

    # Notify A that processing is complete. A failure to notify should NOT
    # fail the whole request - C did its job - so we log it and continue.
    callback_outcome = "sent"
    try:
        log_event(log, "notifying_service_a", "sending completion callback to A",
                  request_id=rid, target=SERVICE_A_URL)
        requests.post(
            f"{SERVICE_A_URL}/callback",
            json={"completed_by": SERVICE_NAME, "request_id": rid},
            headers={REQUEST_ID_HEADER: rid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
    except requests.exceptions.RequestException as exc:
        callback_outcome = "failed"
        log_event(log, "callback_error",
                  f"could not notify Service A: {exc}",
                  request_id=rid, target=SERVICE_A_URL,
                  outcome="failure", level=30)  # WARNING, not fatal

    duration_ms = round((time.time() - started) * 1000, 1)
    log_event(log, "request_completed", "processing complete",
              request_id=rid, status=200, outcome="success",
              callback=callback_outcome, duration_ms=duration_ms)

    return jsonify(
        service=SERVICE_NAME,
        request_id=rid,
        outcome="success",
        callback=callback_outcome,
    ), 200


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
              bind=BIND_HOST, port=SERVICE_PORT, callback_target=SERVICE_A_URL)
    app.run(host=BIND_HOST, port=SERVICE_PORT, threaded=True)
