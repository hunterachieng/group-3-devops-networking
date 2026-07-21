"""
Shared OpenTelemetry tracing helpers used by all three services.

Why this exists:
  The assignment requires a request to be followable across service
  boundaries (gateway -> order -> inventory -> payment). Instrumenting
  Flask gives each incoming request its own span; instrumenting the
  `requests` library makes every outgoing call automatically inject a
  W3C `traceparent` header and start a child span - so order/inventory/
  payment's existing `requests.post(...)` calls propagate trace context
  with no changes to business logic.

Design notes:
  - Exporter is OTLP/HTTP (not gRPC) to avoid a grpcio dependency in the
    slim base image - Jaeger's all-in-one image accepts OTLP over HTTP
    on :4318 same as it does over gRPC on :4317.
  - RequestsInstrumentor().instrument() is process-global and
    FlaskInstrumentor().instrument_app() is idempotent per app, so
    calling init_tracing() multiple times in the same process (e.g. the
    test suite importing all three service modules) is safe.
  - Respects OTEL_SDK_DISABLED so tests don't spend time exporting
    spans to a Jaeger collector that isn't running (see conftest.py).
"""
import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.resources import SERVICE_NAME as SERVICE_NAME_ATTR, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

_requests_instrumented = False


def init_tracing(app, service_name: str) -> None:
    """Wire Flask + requests instrumentation and export spans to Jaeger.

    Call once per service, right after `init_metrics(app, SERVICE_NAME)`:
        init_tracing(app, SERVICE_NAME)
    """
    if not isinstance(trace.get_tracer_provider(), TracerProvider):
        endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://jaeger:4318") + "/v1/traces"
        provider = TracerProvider(
            resource=Resource.create({SERVICE_NAME_ATTR: service_name})
        )
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint)))
        trace.set_tracer_provider(provider)

    FlaskInstrumentor().instrument_app(app)

    global _requests_instrumented
    if not _requests_instrumented:
        RequestsInstrumentor().instrument()
        _requests_instrumented = True


def current_trace_ids() -> tuple[str, str] | tuple[None, None]:
    """Return (trace_id, span_id) as hex strings for the active span, or
    (None, None) if there is no active/valid span (e.g. tracing disabled)."""
    ctx = trace.get_current_span().get_span_context()
    if not ctx.is_valid:
        return None, None
    return format(ctx.trace_id, "032x"), format(ctx.span_id, "016x")
