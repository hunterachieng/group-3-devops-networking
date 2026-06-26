"""
Order service  -  the public-facing entrypoint (port 3001).

E-commerce role: receives a customer checkout, reserves inventory, and is
notified when payment confirms the order.

Flow:   client -> [order] -> inventory -> payment -> (callback) -> [order]

Responsibilities:
  - GET  /health    liveness probe
  - POST /checkout  public entrypoint (the only thing Nginx will proxy)
  - POST /confirm   receives the payment-confirmed callback from Payment
  - structured JSON logs for everything

This is the ONLY service Nginx exposes. Inventory and Payment sit behind it.
"""

import os
import sys
import time
import uuid

import requests
from flask import Flask, request, jsonify

try:
    from services.common.logging_setup import get_logger, log_event
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from common.logging_setup import get_logger, log_event  # noqa: E402

SERVICE_NAME = "order-service"

# Config via environment - nothing hardcoded. Downstream is referenced by NAME.
BIND_HOST = os.getenv("BIND_HOST", "127.0.0.1")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "3001"))
INVENTORY_URL = os.getenv("INVENTORY_URL", "http://inventory.internal:3002")
DOWNSTREAM_TIMEOUT = float(os.getenv("DOWNSTREAM_TIMEOUT", "5"))

REQUEST_ID_HEADER = "X-Request-ID"   # random trace id (one per request)
ORDER_ID_HEADER = "X-Order-ID"       # business id (one per order)

log = get_logger(SERVICE_NAME)
app = Flask(__name__)


def request_id_from(req) -> str:
    """Reuse the incoming trace id, or mint one if this is the front door."""
    return req.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())


def order_id_from(req) -> str:
    """Reuse the incoming order id, or mint one for a brand-new checkout."""
    return req.headers.get(ORDER_ID_HEADER) or f"ORD-{uuid.uuid4().hex[:8].upper()}"


@app.get("/health")
def health():
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried",
              request_id=rid, path="/health", outcome="ok")
    return jsonify(status="ok", service=SERVICE_NAME), 200


@app.get("/ready")
def ready():
    """Readiness probe — reports whether downstream dependencies are reachable."""
    rid = request_id_from(request)
    deps = {"inventory": False}
    try:
        r = requests.get(f"{INVENTORY_URL}/ready", timeout=2)
        deps["inventory"] = r.status_code == 200
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


@app.post("/checkout")
def checkout():
    """Customer places an order. Order reserves inventory to start the pipeline."""
    rid = request_id_from(request)
    oid = order_id_from(request)
    started = time.time()

    # Accept a real cart if sent; otherwise use a sample so demos are one-liners.
    cart = request.get_json(silent=True) or {"items": ["SKU-1", "SKU-2"], "amount": 4200}
    order = {"order_id": oid, **cart}

    log_event(log, "checkout_received", "customer checkout received",
              request_id=rid, order_id=oid, method="POST", path="/checkout",
              amount=order.get("amount"))

    try:
        log_event(log, "reserving_inventory", "asking Inventory to reserve stock",
                  request_id=rid, order_id=oid, target=INVENTORY_URL)

        resp = requests.post(
            f"{INVENTORY_URL}/reserve",
            json=order,
            headers={REQUEST_ID_HEADER: rid, ORDER_ID_HEADER: oid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        resp.raise_for_status()

        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "checkout_completed", "checkout pipeline finished",
                  request_id=rid, order_id=oid, status=200, outcome="success",
                  duration_ms=duration_ms)

        return jsonify(service=SERVICE_NAME, request_id=rid, order_id=oid,
                       outcome="success", pipeline=resp.json()), 200

    except requests.exceptions.RequestException as exc:
        duration_ms = round((time.time() - started) * 1000, 1)
        log_event(log, "downstream_error",
                  f"inventory unreachable: {exc}",
                  request_id=rid, order_id=oid, target=INVENTORY_URL,
                  outcome="failure", status=502, duration_ms=duration_ms, level=40)
        return jsonify(service=SERVICE_NAME, request_id=rid, order_id=oid,
                       outcome="failure", error="inventory service unavailable"), 502


@app.post("/confirm")
def confirm():
    """
    Payment calls this when the charge succeeds. This is the order-confirmation
    step and proves the full round trip, logged under the SAME request + order id.
    """
    rid = request_id_from(request)
    oid = order_id_from(request)
    payload = request.get_json(silent=True) or {}
    log_event(log, "order_confirmed", "payment confirmed; order complete",
              request_id=rid, order_id=oid, path="/confirm",
              source="payment-service", detail=payload, outcome="ok")
    return jsonify(status="confirmed", service=SERVICE_NAME,
                   request_id=rid, order_id=oid), 200


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
              bind=BIND_HOST, port=SERVICE_PORT, downstream=INVENTORY_URL)
    app.run(host=BIND_HOST, port=SERVICE_PORT, threaded=True)
