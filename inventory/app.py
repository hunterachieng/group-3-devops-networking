"""
Inventory service  -  internal service (port 3002).

E-commerce role: reserves stock for an order, then hands off to Payment to
charge the customer.

Responsibilities:
  - GET  /health   liveness probe
  - GET  /version  returns current git SHA (required for Phase 2 checkpoint)
  - POST /reserve  receive order from Order, reserve stock, call Payment
  - structured JSON logs for everything
"""

import os
import time
import uuid

import requests
from flask import Flask, request, jsonify

from common.logging_setup import get_logger, log_event
from common.metrics import init_metrics
from common.tracing import init_tracing
from common.failures import init_failures

SERVICE_NAME = "inventory-service"
GIT_SHA = os.environ.get("GIT_SHA", "dev")

BIND_HOST = os.getenv("BIND_HOST", "0.0.0.0")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "3002"))
PAYMENT_URL = os.getenv("PAYMENT_URL", "http://payment:3003")
DOWNSTREAM_TIMEOUT = float(os.getenv("DOWNSTREAM_TIMEOUT", "5"))

REQUEST_ID_HEADER = "X-Request-ID"
ORDER_ID_HEADER = "X-Order-ID"

log = get_logger(SERVICE_NAME)
app = Flask(__name__)
init_metrics(app, SERVICE_NAME)
init_tracing(app, SERVICE_NAME)
init_failures(app, SERVICE_NAME, log, log_event, downstream_url=PAYMENT_URL)


def request_id_from(req) -> str:
    return req.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())


def order_id_from(req) -> str:
    return req.headers.get(ORDER_ID_HEADER) or f"ORD-{uuid.uuid4().hex[:8].upper()}"


@app.get("/health")
def health():
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried",
              request_id=rid, path="/health", outcome="ok")
    return jsonify(status="ok", service=SERVICE_NAME, version=GIT_SHA), 200


@app.get("/version")
def version():
    return jsonify(service="inventory", version=GIT_SHA, status="ok"), 200


@app.get("/ready")
def ready():
    """Readiness probe — reports whether downstream dependencies are reachable."""
    rid = request_id_from(request)
    deps = {"payment": False}
    try:
        r = requests.get(f"{PAYMENT_URL}/health", timeout=2)
        deps["payment"] = r.status_code == 200
    except requests.exceptions.RequestException:
        pass

    all_ready = all(deps.values())
    status_code = 200 if all_ready else 503
    log_event(log, "readiness_check", "readiness probe",
              request_id=rid, path="/ready",
              outcome="ready" if all_ready else "not_ready",
              dependencies=deps,
              level=20 if all_ready else 30)
    return jsonify(status="ready" if all_ready else "not_ready",
                   service=SERVICE_NAME, dependencies=deps), status_code


@app.post("/reserve")
def reserve():
    rid = request_id_from(request)
    oid = order_id_from(request)
    started = time.time()
    order = request.get_json(silent=True) or {}

    log_event(log, "reserve_received", "reserve request received from Order",
              request_id=rid, order_id=oid, method="POST", path="/reserve",
              items=order.get("items"))

    log_event(log, "stock_reserved", "stock reserved for order",
              request_id=rid, order_id=oid, outcome="ok")

    try:
        log_event(log, "charging_payment", "handing off to Payment to charge",
                  request_id=rid, order_id=oid, target=PAYMENT_URL)

        resp = requests.post(
            f"{PAYMENT_URL}/charge",
            json=order,
            headers={REQUEST_ID_HEADER: rid, ORDER_ID_HEADER: oid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        resp.raise_for_status()

        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "reserve_completed", "reserved and payment handed off",
                  request_id=rid, order_id=oid, status=200, outcome="success",
                  duration_ms=duration_ms)

        return jsonify(service=SERVICE_NAME, request_id=rid, order_id=oid,
                       outcome="success", downstream=resp.json()), 200

    except requests.exceptions.RequestException as exc:
        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "downstream_error",
                  f"payment unreachable: {exc}",
                  request_id=rid, order_id=oid, target=PAYMENT_URL,
                  outcome="failure", status=502, duration_ms=duration_ms, level=40)
        return jsonify(service=SERVICE_NAME, request_id=rid, order_id=oid,
                       outcome="failure", error="payment service unavailable"), 502


@app.errorhandler(404)
def not_found(_err):
    rid = request_id_from(request)
    oid = request.headers.get(ORDER_ID_HEADER)
    log_event(log, "not_found", "request to unknown endpoint",
              request_id=rid, order_id=oid, method=request.method,
              path=request.path, status=404, outcome="rejected", level=30)
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
              bind=BIND_HOST, port=SERVICE_PORT, downstream=PAYMENT_URL,
              version=GIT_SHA)
    app.run(host=BIND_HOST, port=SERVICE_PORT, threaded=True)
