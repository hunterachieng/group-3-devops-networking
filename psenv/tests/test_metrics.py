"""
Tests for services/common/metrics.py, exercised through the order app
(the pattern is identical for inventory/payment since they all call
init_metrics the same way).

Design note: the Counter/Histogram/Gauge objects in metrics.py are
module-level singletons, and services.order.app is only imported once
per test process (Python caches modules). So state accumulates across
tests in this file exactly like it would across requests in a running
service - we assert on *deltas*, not absolute values.

PROMETHEUS_MULTIPROC_DIR is set once, session-wide, in conftest.py -
see that file for why it can't be set here instead.
"""
import pytest

from services.order import app as order_app_module


@pytest.fixture(scope="module")
def client():
    order_app_module.app.config["TESTING"] = True
    order_app_module.app.config["PROPAGATE_EXCEPTIONS"] = False
    with order_app_module.app.test_client() as c:
        yield c


def _metric_value(body: str, exact_line_prefix: str, default: float = None) -> float:
    """Find a metrics line by exact prefix (name + labels) and return its
    value. With no default, raises if not found (metric must exist).
    With a default, a not-yet-seen label combination (e.g. before the
    first request of a given kind) returns the default instead."""
    for line in body.splitlines():
        if line.startswith(exact_line_prefix):
            return float(line.rsplit(" ", 1)[-1])
    if default is not None:
        return default
    raise AssertionError(f"metric line not found: {exact_line_prefix!r}\n---\n{body}")


def test_metrics_endpoint_returns_200_and_prometheus_content_type(client):
    r = client.get("/metrics")
    assert r.status_code == 200
    assert r.content_type.startswith("text/plain")


def test_service_up_gauge_is_reported(client):
    body = client.get("/metrics").get_data(as_text=True)
    assert _metric_value(body, 'service_up{service="order-service"}') == 1.0


def test_http_requests_total_counts_a_real_request(client):
    line = 'http_requests_total{method="GET",route="/health",service="order-service",status_code="200"}'
    before = _metric_value(client.get("/metrics").get_data(as_text=True), line, default=0.0)
    client.get("/health")
    after = _metric_value(client.get("/metrics").get_data(as_text=True), line)
    assert after == before + 1


def test_unmatched_route_does_not_leak_raw_path_as_a_label(client):
    """A 404 to a garbage/unknown path must collapse to route="unmatched",
    not create a brand new label value per request (cardinality bomb)."""
    client.get("/this-path-does-not-exist")
    body = client.get("/metrics").get_data(as_text=True)
    assert "/this-path-does-not-exist" not in body
    assert 'route="unmatched"' in body


def test_duration_histogram_records_a_sample(client):
    line = 'http_request_duration_seconds_count{method="GET",route="/health",service="order-service"}'
    before = _metric_value(client.get("/metrics").get_data(as_text=True), line, default=0.0)
    client.get("/health")
    after = _metric_value(client.get("/metrics").get_data(as_text=True), line)
    assert after == before + 1


def test_5xx_response_increments_http_errors_total(client, monkeypatch):
    """Force an unhandled exception inside /checkout (not the
    requests.exceptions.RequestException path, which the service already
    catches and turns into a handled 502) so Flask's real 500 error
    handler fires, exactly like an unexpected bug in production would."""
    def _raise(*_args, **_kwargs):
        raise RuntimeError("forced failure for test")

    monkeypatch.setattr(order_app_module.requests, "post", _raise)

    line = 'http_errors_total{route="/checkout",service="order-service"}'
    before = _metric_value(client.get("/metrics").get_data(as_text=True), line, default=0.0)

    r = client.post("/checkout", json={"items": ["SKU-1"], "amount": 100})
    assert r.status_code == 500

    after = _metric_value(client.get("/metrics").get_data(as_text=True), line)
    assert after == before + 1