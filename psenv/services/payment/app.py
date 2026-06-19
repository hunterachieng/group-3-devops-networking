"""
Payment service  -  internal service (port 3003).

E-commerce role: charges the customer, then notifies Order that payment
succeeded so the order can be confirmed (the callback).

Responsibilities:
  - GET  /health  liveness probe
  - POST /charge  receive from Inventory, charge, then confirm back to Order
  - structured JSON logs for everything

Internal infrastructure: loopback-bound, never proxied by Nginx.
"""

import os
import sys
import time
import uuid

import requests
from flask import Flask, request, jsonify

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common.logging_setup import get_logger, log_event  # noqa: E402

SERVICE_NAME = "payment-service"

BIND_HOST = os.getenv("BIND_HOST", "127.0.0.1")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "3003"))
# Payment confirms back to Order, so it needs Order's address - by name.
ORDER_URL = os.getenv("ORDER_URL", "http://order.internal:3001")
DOWNSTREAM_TIMEOUT = float(os.getenv("DOWNSTREAM_TIMEOUT", "5"))

REQUEST_ID_HEADER = "X-Request-ID"
ORDER_ID_HEADER = "X-Order-ID"

log = get_logger(SERVICE_NAME)
app = Flask(__name__)


def request_id_from(req) -> str:
    return req.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())


def order_id_from(req) -> str:
    return req.headers.get(ORDER_ID_HEADER) or f"ORD-{uuid.uuid4().hex[:8].upper()}"


@app.get("/health")
def health():
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried",
              request_id=rid, path="/health", outcome="ok")
    return jsonify(status="ok", service=SERVICE_NAME), 200


@app.post("/charge")
def charge():
    rid = request_id_from(request)
    oid = order_id_from(request)
    started = time.time()
    order = request.get_json(silent=True) or {}
    amount = order.get("amount")

    log_event(log, "charge_received", "charge request received from Inventory",
              request_id=rid, order_id=oid, method="POST", path="/charge",
              amount=amount)

    # Pretend to charge the card.
    log_event(log, "payment_captured", "payment captured",
              request_id=rid, order_id=oid, amount=amount, outcome="ok")
    time.sleep(0.05)

    # Confirm back to Order. A failed confirm should NOT fail the charge -
    # the money was taken - so we log it and carry on.
    confirm_outcome = "sent"
    try:
        log_event(log, "confirming_order", "notifying Order that payment confirmed",
                  request_id=rid, order_id=oid, target=ORDER_URL)
        requests.post(
            f"{ORDER_URL}/confirm",
            json={"order_id": oid, "amount": amount, "confirmed_by": SERVICE_NAME},
            headers={REQUEST_ID_HEADER: rid, ORDER_ID_HEADER: oid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
    except requests.exceptions.RequestException as exc:
        confirm_outcome = "failed"
        log_event(log, "confirm_error",
                  f"could not confirm order with Order service: {exc}",
                  request_id=rid, order_id=oid, target=ORDER_URL,
                  outcome="failure", level=30)

    duration_ms = round((time.time() - started) * 1000, 1)
    log_event(log, "charge_completed", "charge complete",
              request_id=rid, order_id=oid, status=200, outcome="success",
              confirm=confirm_outcome, duration_ms=duration_ms)

    return jsonify(service=SERVICE_NAME, request_id=rid, order_id=oid,
                   outcome="success", amount=amount, confirm=confirm_outcome), 200


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
              bind=BIND_HOST, port=SERVICE_PORT, callback_target=ORDER_URL)
    app.run(host=BIND_HOST, port=SERVICE_PORT, threaded=True)
