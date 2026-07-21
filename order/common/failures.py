"""
Shared controlled-failure endpoints used by all three services.

These lab-only routes let us prove the telemetry moves under failure: a 5xx
spikes http_errors_total and fires HighErrorRate, a slow response pushes p95
latency and fires HighLatency, and a downstream failure shows a broken span in
Jaeger. All three services import them from here so the endpoints, labels, and
logs are identical.

Safety:
  These endpoints inject faults and must never be reachable in a real
  deployment. They are registered only when ENABLE_FAILURE_ENDPOINTS is truthy
  (1/true/yes/on). docker-compose.prod.yml leaves it unset, so the routes do
  not exist there.

Endpoints (registered when enabled):
  GET/POST /fail             -> 500, drives http_errors_total + HighErrorRate
  GET/POST /slow             -> sleeps FAIL_SLOW_SECONDS, drives p95 + HighLatency
  GET/POST /error            -> structured error log path, returns 500
  GET/POST /dependency-fail  -> calls a failing downstream, returns 502 and
                                produces a broken cross-service trace span
"""
import os
import time

import requests
from flask import jsonify, request

REQUEST_ID_HEADER = "X-Request-ID"
ORDER_ID_HEADER = "X-Order-ID"


def _truthy(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


def failures_enabled() -> bool:
    """True when lab-only fault-injection endpoints should be registered."""
    return _truthy(os.getenv("ENABLE_FAILURE_ENDPOINTS", "false"))


def init_failures(app, service_name, log, log_event, downstream_url=None):
    """Register the lab-only failure endpoints on `app`.

    No-op unless ENABLE_FAILURE_ENDPOINTS is truthy, so this is safe to
    call unconditionally right after init_tracing(app, SERVICE_NAME).

    downstream_url : the next service in the pipeline (order->inventory,
                     inventory->payment, payment->order). /dependency-fail
                     calls its /fail route so the trace spans two services.
    """
    if not failures_enabled():
        return

    default_slow = float(os.getenv("FAIL_SLOW_SECONDS", "1.0"))
    downstream_timeout = float(os.getenv("DOWNSTREAM_TIMEOUT", "5"))

    def _rid():
        return request.headers.get(REQUEST_ID_HEADER) or "no-request-id"

    def _oid():
        return request.headers.get(ORDER_ID_HEADER)

    @app.route("/fail", methods=["GET", "POST"])
    def fail():
        """Always return 500 — drives http_errors_total and HighErrorRate."""
        rid = _rid()
        log_event(log, "lab_fail", "lab-only forced 500 failure",
                  request_id=rid, order_id=_oid(), path="/fail",
                  status=500, outcome="forced_failure", level=40)
        return jsonify(service=service_name, request_id=rid,
                       error="forced failure (lab)", endpoint="/fail"), 500

    @app.route("/slow", methods=["GET", "POST"])
    def slow():
        """Sleep, then return 200 — drives request duration / p95 latency."""
        rid = _rid()
        delay = request.args.get("seconds", type=float)
        if delay is None:
            delay = default_slow
        delay = max(0.0, min(delay, 30.0))  # clamp so a typo can't hang forever
        log_event(log, "lab_slow", "lab-only injected latency",
                  request_id=rid, order_id=_oid(), path="/slow",
                  delay_seconds=delay, outcome="slow", level=30)
        time.sleep(delay)
        return jsonify(service=service_name, request_id=rid,
                       endpoint="/slow", slept_seconds=delay), 200

    @app.route("/error", methods=["GET", "POST"])
    def error():
        """Take a structured error path (exception -> logged -> 500)."""
        rid = _rid()
        try:
            raise RuntimeError("lab-only structured error path triggered")
        except RuntimeError as exc:
            log_event(log, "lab_error", f"structured error path: {exc}",
                      request_id=rid, order_id=_oid(), path="/error",
                      status=500, outcome="error", error_type="RuntimeError",
                      level=40)
            return jsonify(service=service_name, request_id=rid,
                           error="structured error (lab)", endpoint="/error"), 500

    @app.route("/dependency-fail", methods=["GET", "POST"])
    def dependency_fail():
        """Call a failing downstream so the trace shows a broken span.

        Hits the downstream service's /fail route (a real 500) so the
        request propagates trace context and Jaeger shows exactly where
        the pipeline broke. Returns 502 upstream, mirroring the real
        downstream-error handling in checkout/reserve.
        """
        rid = _rid()
        oid = _oid()
        if not downstream_url:
            log_event(log, "lab_dependency_fail",
                      "no downstream configured; simulating local dependency failure",
                      request_id=rid, order_id=oid, path="/dependency-fail",
                      status=502, outcome="failure", level=40)
            return jsonify(service=service_name, request_id=rid,
                           error="downstream dependency unavailable (lab)",
                           endpoint="/dependency-fail"), 502

        target = f"{downstream_url}/fail"
        try:
            log_event(log, "lab_dependency_fail_call",
                      "calling failing downstream dependency",
                      request_id=rid, order_id=oid, path="/dependency-fail",
                      target=target)
            resp = requests.post(
                target,
                headers={REQUEST_ID_HEADER: rid,
                         **({ORDER_ID_HEADER: oid} if oid else {})},
                timeout=downstream_timeout,
            )
            resp.raise_for_status()
            # Downstream unexpectedly succeeded (e.g. its failures are disabled).
            return jsonify(service=service_name, request_id=rid,
                           endpoint="/dependency-fail",
                           downstream_status=resp.status_code), 200
        except requests.exceptions.RequestException as exc:
            log_event(log, "lab_dependency_fail",
                      f"downstream dependency failed: {exc}",
                      request_id=rid, order_id=oid, target=target,
                      status=502, outcome="failure", level=40)
            return jsonify(service=service_name, request_id=rid,
                           error="downstream dependency failed (lab)",
                           endpoint="/dependency-fail", target=target), 502
