# Jaeger: distributed tracing

Service mapping: **A = order, B = inventory, C = payment.** Trace path:

```
nginx → order → inventory → payment ──confirm callback──→ order
```

Every incoming request gets a span (Flask auto-instrumentation). Every
outgoing `requests.post(...)` call between services gets a child span and
automatically injects a W3C `traceparent` header (requests
auto-instrumentation) — that's how one trace ID survives all three hops with
no changes to business logic. The existing `X-Request-ID` header is kept
alongside it as the business/order correlation ID; `trace_id` is the
OpenTelemetry correlation ID, and both show up together in the structured
JSON logs (see `services/common/logging_setup.py`).

## Access

- **Dev (`docker-compose.yml`):** Jaeger UI at http://localhost:16686
- **Prod (`docker-compose.prod.yml`):** Jaeger has no published host port
  (same "only nginx faces the internet" invariant as Prometheus). To view it
  during a demo, either tunnel it or run from the host running Compose:
  ```bash
  docker compose -f docker-compose.prod.yml exec jaeger true  # confirm it's up
  ssh -L 16686:localhost:16686 <deploy-host>                  # then open locally
  ```
  (the SSH command above binds the container's internal port to your local
  machine over the existing SSH connection to the deploy host — swap in your
  Jaeger container's actual reachable address if it isn't `localhost` there.)

Services send spans to Jaeger over OTLP/HTTP at `http://jaeger:4318`
(`OTEL_EXPORTER_OTLP_ENDPOINT` in both compose files) — the Jaeger
all-in-one image accepts OTLP directly, no separate collector needed.

## Required trace demo

### 1. Successful request — full path across all three services

```bash
docker compose up --build -d
curl -s -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"items": ["SKU-1"], "amount": 4200}' | jq
```

Open http://localhost:16686, set **Service** to `order-service`, click
**Find Traces**, and open the most recent one. You should see nested spans
for the full journey:

```
order-service: POST /checkout
  └─ order-service: POST http://inventory:3002/reserve   (outgoing span)
       └─ inventory-service: POST /reserve                (incoming span, same trace)
            └─ inventory-service: POST http://payment:3003/charge
                 └─ payment-service: POST /charge
                      └─ payment-service: POST http://order:3001/confirm
                           └─ order-service: POST /confirm
```

Each span shows service name, endpoint, duration, and status — this is the
same trace ID that appears as `trace_id` in the JSON logs for every one of
those log lines, so a slow or failing hop can be jumped to directly.

### 2. Slow/failing endpoint — show where it breaks in the trace

Stop the payment service to force a downstream failure:

```bash
docker compose stop payment
curl -s -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"items": ["SKU-1"], "amount": 4200}' | jq
docker compose start payment
```

In Jaeger, find the new trace for `order-service`. The `inventory-service:
POST http://payment:3003/charge` span is marked **error** (red) with the
connection failure, and the parent `POST /reserve` and `POST /checkout`
spans propagate `outcome: failure` — this is the same failure that shows up
as a `downstream_error` log line (`trace_id` matches) and as a 502 to the
client.

## Trace context vs. request ID

| Field        | Set by                              | Purpose                                   |
|--------------|--------------------------------------|--------------------------------------------|
| `trace_id`   | OpenTelemetry (`traceparent` header)  | Follow one request across all services in Jaeger |
| `request_id` | Custom `X-Request-ID` header          | Business/log correlation, independent of tracing backend |
| `order_id`   | Custom `X-Order-ID` header             | Correlate every hop for one customer order |

Both IDs are logged on every line so a trace found in Jaeger and a log line
found via `docker compose logs` or `grep` always point at the same event.
