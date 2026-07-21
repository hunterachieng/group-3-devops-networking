"""
Shared Prometheus metrics helpers used by all three services.

Why multiprocess mode:
  Each service runs under gunicorn with multiple worker *processes*
  (see docker-compose.yml, --workers 2). A plain in-process
  prometheus_client registry lives inside a single worker's memory, so
  a naive /metrics endpoint would only ever report whatever that one
  worker happened to see - silently dropping everything the other
  worker handled. prometheus_client's multiprocess mode fixes this:
  every worker writes its counters to files in PROMETHEUS_MULTIPROC_DIR,
  and /metrics aggregates across all of them on each scrape.

  This requires two things outside this file:
    1. PROMETHEUS_MULTIPROC_DIR set to a writable directory (compose env).
    2. A gunicorn `child_exit` hook calling multiprocess.mark_process_dead
       so a recycled/crashed worker's old data doesn't linger forever
       (see psenv/gunicorn.conf.py).

Metric names/labels (contract with dashboards + alerts):
  http_requests_total{service,method,route,status_code}   counter
  http_request_duration_seconds{service,method,route}     histogram
  http_errors_total{service,route}                         counter (5xx only)
  service_up{service}                                      gauge (1 = up)
"""
import os
import time

from flask import request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    multiprocess,
)

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests received",
    ["service", "method", "route", "status_code"],
)

HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["service", "method", "route"],
)

HTTP_ERRORS_TOTAL = Counter(
    "http_errors_total",
    "Total HTTP responses with a 5xx status code",
    ["service", "route"],
)

# multiprocess_mode="max": if ANY worker for this service is alive and has
# set itself to 1, the aggregated gauge reads 1. Avoids a stopped worker's
# stale 0/1 flapping the value under normal recycling.
SERVICE_UP = Gauge(
    "service_up",
    "1 if the service process is up",
    ["service"],
    multiprocess_mode="max",
)


def _route_label() -> str:
    """Use the matched Flask route rule (e.g. '/reserve'), not the raw
    path, so path params or unmatched garbage can't blow up cardinality."""
    if request.url_rule is not None:
        return request.url_rule.rule
    return "unmatched"


def init_metrics(app, service_name: str) -> None:
    """Wire before/after_request hooks and expose GET /metrics.

    Call once per service, right after `app = Flask(__name__)`:
        init_metrics(app, SERVICE_NAME)
    """
    SERVICE_UP.labels(service=service_name).set(1)

    @app.before_request
    def _metrics_start_timer():
        request._metrics_started = time.time()

    @app.after_request
    def _metrics_record(response):
        route = _route_label()
        started = getattr(request, "_metrics_started", None)
        duration = time.time() - started if started is not None else 0.0

        HTTP_REQUESTS_TOTAL.labels(
            service=service_name,
            method=request.method,
            route=route,
            status_code=response.status_code,
        ).inc()

        HTTP_REQUEST_DURATION_SECONDS.labels(
            service=service_name,
            method=request.method,
            route=route,
        ).observe(duration)

        if response.status_code >= 500:
            HTTP_ERRORS_TOTAL.labels(service=service_name, route=route).inc()

        return response

    @app.get("/metrics")
    def metrics():
        multiproc_dir = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
        if multiproc_dir:
            registry = CollectorRegistry()
            multiprocess.MultiProcessCollector(registry)
        else:
            # Dev fallback: running `python app.py` directly (single
            # process, no gunicorn) - the default global registry works.
            registry = REGISTRY
        return Response(generate_latest(registry), mimetype=CONTENT_TYPE_LATEST)